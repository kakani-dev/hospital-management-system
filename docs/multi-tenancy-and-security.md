# Multi-tenancy & security design

_Owners (simulated): Security Team, Database Engineering Team. Status: Sprint 1._

> **PR #1 review fixes.** Sections marked _(PR #1 fix contract)_ describe the behaviour agreed in the PR #1 fix plan (review findings B1, M1, M2, M3 and Minor 1). They are the target state once the fix branches are merged into `feat/sprint-1-identity`. Until then the regression tests listed under [Verified by tests](#verified-by-tests) are expected to fail. **Scope:** the only database change in this round is the B1 invite fix. M1 and M2 are enforced in the **API only**. The database hardening for them (and `FORCE ROW LEVEL SECURITY`) is deferred; see [Known gaps / backlog](#known-gaps--backlog).

## Principles

1. **Every tenant-owned row has a `tenant_id`.** This is `NOT NULL` and has a foreign key to `identity.tenants`. It is enforced by `supabase/tests/01_schema_guardrails_test.sql`.
2. **The client never chooses the tenant.** The tenant always comes from server-controlled, signed token claims, and is then checked against `identity.memberships`.
3. **Defense in depth.** Isolation is enforced in the API (resolved tenant context, EF global query filters, save interceptor, role/branch checks) **and** in PostgreSQL (RLS, column grants, composite FKs, triggers).
4. **Fail closed.** No resolved tenant means no rows. Unconfigured auth means every token is rejected. Unknown ids get a 404 that does not reveal whether the row exists.

## Tenant model

| Table | Tenant-owned? | Notes |
|---|---|---|
| `identity.tenants` | root | `id` is the tenant id. Only the service role can create tenants. |
| `identity.branches` | yes | `unique (tenant_id, code)`, `unique (tenant_id, id)` |
| `identity.user_profiles` | **no (documented exception)** | 1:1 with `auth.users`. One person, such as a visiting consultant, can belong to several hospitals. |
| `identity.memberships` | yes | `(tenant_id, user_id, branch_id, role, status)`. `branch_id NULL` means all branches. This table is the single source of truth for access. |
| `patient.patients` | yes | `unique (tenant_id, mrn)`, composite FK `(tenant_id, registered_branch_id)` |
| `audit.audit_log` | yes | Append-only and written only by a trigger |

**Composite foreign keys** (`(tenant_id, branch_id) → branches(tenant_id, id)`) make it impossible, even for privileged code, to point a row at another tenant's branch.

## How the tenant is resolved

### API (`Hms.Modules.Identity.Tenancy`)

1. The JWT bearer handler validates the Supabase token against the project's JWKS (ES256/RS256; HS256 only with a configured legacy secret), plus issuer, audience `authenticated`, lifetime and `role = authenticated`. See [auth-flow.md](auth-flow.md).
2. `ClaimsTenantResolver` reads `sub`, plus `tenant_id`/`branch_id` from either a top-level claim (custom access token hook) or `app_metadata`. Users cannot edit `app_metadata`. `user_metadata`, headers, query strings and bodies are **ignored**. If the token has **no** tenant claim, the server-side stored/default context (`identity.my_active_context()`) is used. A present-but-invalid claim never falls back.
3. `EfMembershipStore` confirms an **active** membership in an **active** tenant (queried as the user, under RLS). If a branch is pinned, it must be an active branch inside the user's branch scope.
4. `TenantContext` (scoped) is filled in, and `DbSessionContext` is pinned to the user + tenant. `.RequireTenant()` endpoints return **403** when it is not resolved.
5. `PatientsDbContext` applies `TenantId == resolved tenant && DeletedAt == null` as a global query filter.
6. `TenantSaveChangesInterceptor` overwrites `TenantId` on insert, blocks `TenantId` changes, and throws if no tenant is resolved.

### API database role (RLS applies to API traffic)

The API never connects as the table owner:

| Role | Attributes | Privileges |
|---|---|---|
| `hms_api` | `NOLOGIN NOINHERIT` | none directly. Member of `authenticated` and `anon`, so it may `SET ROLE` to them. |
| `hms_api_login` | `LOGIN NOINHERIT` (created out-of-band, password in a secret store) | member of `hms_api` only |

Every API request runs inside a transaction (`WithDbTransaction<TContext>()`; commit on status < 400, roll back otherwise). `RlsTransactionInterceptor` runs at the start of each transaction:

```sql
select set_config('role', 'authenticated', true),                 -- or 'anon' when unauthenticated
       set_config('request.jwt.claims', '{"sub":…,"role":"authenticated","tenant_id":…}', true),
       set_config('request.jwt.claim.sub', '<user id>', true);
```

The claims are built only from the **validated** JWT and the **server-resolved** tenant. Everything is transaction-local, so it is safe with a transaction-mode pooler (Supavisor :6543). Consequences, all covered by tests:

- A query outside a transaction has no privileges: `permission denied` (fail closed).
- With the EF query filter **bypassed** (`IgnoreQueryFilters`) or pointed at the wrong tenant, Postgres still returns only rows the user may see. A buggy cross-tenant insert fails with `42501`.
- `hms_api_login` cannot `SET ROLE service_role`, `postgres` or `supabase_auth_admin`, cannot disable `row_security`, and cannot execute the access token hook.
- `audit_log.changed_by` and `created_by/updated_by` record the real end user, taken from `request.jwt.claim.sub`.

### `hms_api` trust model (review Minor 1)

`hms_api` is low-privilege **for grants**, but it is **fully trusted for identity**. Postgres believes whatever `sub` / `tenant_id` the API writes into `request.jwt.claims`. Anyone holding the `hms_api_login` credentials can therefore set `sub` to any user (for example another hospital's tenant admin) and read or write everything that user may access under RLS. This was reproduced in review (PoC P5: `hms_api_login` set `sub` to the Beta admin and read Beta's patients). It is the same model as PostgREST's `authenticator` role. RLS is not a defence against a leaked API credential.

**Treat `hms_api_login` like the Supabase `service_role` key:**

| Control | Requirement |
|---|---|
| Storage | Only in a secret manager / the host's secret store (e.g. a Render secret environment variable for the API service). Never in git, `appsettings*.json`, Docker images, CI logs, or any `VITE_*` variable (those ship to every browser). The local value `hms_api_local_only` in `supabase/scripts/local-api-login-role.sql` is for local and CI throwaway databases only. Never use it on a hosted project. |
| Creation | Out-of-band on the hosted project, never through a migration: `create role hms_api_login login noinherit password '<generated secret>'; grant hms_api to hms_api_login;`. Generate the password with a CSPRNG (32+ random bytes). Nothing is created on the hosted project until it has been approved. |
| Rotation | Rotate on a fixed schedule (recommended: at least every 90 days), whenever someone with access leaves, and **immediately** on any suspected leak. Procedure: `alter role hms_api_login password '<new secret>'`, update the secret store, redeploy/restart the API, then confirm in `pg_stat_activity` that no sessions with the old credential remain (pooled connections stay open until they are recycled). For zero-downtime rotation, run two login roles (e.g. `hms_api_login_a` / `_b`, both `LOGIN NOINHERIT` and members of `hms_api` only) and alternate between them. |
| Network | Only the API hosts may connect. Use Supabase network restrictions and/or the Supavisor allow-list with the API's egress IPs, and do not expose the database to the public internet beyond that. Require TLS (`SSL Mode=VerifyFull` or at least `Require` in the Npgsql connection string). |
| Connection limit | Cap the role so a leaked credential or runaway client cannot exhaust the server: `alter role hms_api_login connection limit <n>;`. Size `n` as _API instances × Npgsql `Maximum Pool Size`_ plus a small headroom (e.g. 1 instance × pool 20 → `connection limit 25`), and revisit it when scaling. |
| Least privilege | `hms_api_login` is a member of `hms_api` only (`NOINHERIT`). `hms_api` is a member of `authenticated` and `anon` only. Never grant `service_role`, `postgres`, `supabase_auth_admin` or `BYPASSRLS` (guarded by `Hms.DatabaseTests` and `supabase/tests/07_api_role_test.sql`). |
| Monitoring | Alert on connections by `hms_api_login` from unexpected client addresses and on failed authentication for the role. |

The API's own JWT validation is the only gate in front of this trust. Keep it fail-closed (see [auth-flow.md](auth-flow.md)).

### Database (RLS)

Helper functions in `identity` are `SECURITY DEFINER` with `search_path = ''`, and they only answer questions about `auth.uid()`:

- `identity.current_tenant_ids()`: active memberships in active tenants, intersected with the optional `app_metadata.tenant_id` pin
- `identity.has_tenant_role(tenant, roles[])`
- `identity.current_branch_ids(tenant)` / `identity.can_access_branch(tenant, branch)`
- `identity.shares_tenant_with(user)` / `identity.is_admin_of_member(user)`
- `identity.active_tenant_claim()`: the top-level `tenant_id` claim (hook), falling back to `app_metadata.tenant_id`

Definer functions callable by `authenticated` (each validates against memberships and raises `42501` otherwise): `identity.my_memberships()`, `identity.my_active_context()`, `identity.set_active_context(tenant, branch)` and `identity.add_member(tenant, email, role, branch)` (tenant_admin only). The hook function `identity.custom_access_token_hook` is executable **only** by `supabase_auth_admin`.

_(PR #1 fix contract, B1)_ Added: `identity.accept_membership(membership_id)` and `identity.my_invitations()` (granted to `authenticated` and `hms_api`). `add_member` now creates **invited** memberships. See [Invitations and consent](#invitations-and-consent-b1).

Policy summary:

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| tenants | members | — (service role) | tenant_admin; only `name` and `settings` (column grant) | — |
| branches | members | tenant_admin | tenant_admin | tenant_admin |
| user_profiles | self + active colleagues + (tenant_admin) any member of their tenant | — | self; only `display_name` | — |
| memberships | own + tenant_admin | tenant_admin | tenant_admin | tenant_admin |
| patients | admin, doctor, nurse, receptionist, billing | admin, doctor, nurse, receptionist, **at an accessible branch** (role and branch are checked separately here; the per-branch rule is enforced in the API only, see [M1](#branch-scoped-write-rules-m1)) | same, and branch rule on the new row; `tenant_id` not updatable | — (soft delete only) |
| audit_log | tenant_admin | — (trigger only) | — (blocked by trigger) | — (blocked by trigger) |

`anon` has no privileges on any HMS schema.

## Roles

`tenant_admin, doctor, nurse, receptionist, billing, pharmacist, lab_technician, viewer`. These are enforced by a CHECK constraint and mirrored in `HmsRoles`. `lab_technician`, `pharmacist` and `viewer` have no access to the patient registry yet. Their access will be designed with their modules.

## Invitations and consent (B1)

_(PR #1 fix contract, incl. the 21:16 IST update.)_ Review finding B1: `add_member` used to create an **active** membership for any platform account with no consent. Because the default tenant was chosen alphabetically, that membership could silently become the victim's **default hospital**. The different 404/409/201 answers also let any tenant admin find out whether an email had an account anywhere on the platform.

**Invite:** `POST /api/v1/members` with `{ email, role, branchId? }`. Only a tenant_admin can invite, and the tenant always comes from the admin's resolved context (never from the body).
- The answer is **always** `202 Accepted` with `{"message":"If an account exists for that email, an invitation has been sent."}`, whether the email has no account, has an account (now invited), or already belongs to the tenant. Status, body and headers must not reveal which case applied.
- Validation errors stay `400` (including a `tenant_admin` with a branch, see M1) and authorization failures stay `403`/`404`. These must not depend on whether the email has an account.
- In the database, `identity.add_member(tenant, email, role, branch)` inserts a membership with `status = 'invited'`. If there is no `auth.users` row it returns `NULL` (no error). If the person is already a member it returns the existing membership id and changes nothing (no status change). Admin authorization checks are unchanged.

**Pending = no access.** An `invited` membership grants nothing. It does not count for RLS, tenant resolution, `/me` roles or branches, or the custom access token hook. Requests scoped to that tenant get `403` (no active membership), exactly as for a non-member.

**Pending invites are hidden from admins.** Listing a pending invite would reveal that the email has an account, so:
- pending invites do not appear in `GET /api/v1/members`;
- any admin `PATCH /api/v1/members/{id}` on a pending membership returns `404`;
- in the database, invited rows are kept out of the admin-visible RLS and out of `is_admin_of_member`, and admins cannot move an invited membership to `active`.

Admins listing or revoking pending invites is a backlog item.

**No default-context change.** The default tenant is resolved as `order by (preferred tenant) desc nulls last, m.created_at, m.tenant_id` (membership age, not tenant name), over **active** memberships only. The first resolved tenant is persisted to `identity.user_profiles.active_tenant_id`. Neither receiving nor accepting an invitation switches the user's context. Only an explicit `POST /api/v1/me/context` does.

**Accept:**
- `GET /api/v1/me/invitations` returns `[{membershipId, tenantId, tenantName, branchId, role, invitedAt}]` from `identity.my_invitations()`.
- `POST /api/v1/me/invitations/{membershipId}/accept` → `204`. Both endpoints work for a signed-in user who has no tenant yet. In the database, `identity.accept_membership(id)` activates the membership only if it belongs to `auth.uid()` and is still `invited`. Otherwise it raises `P0002`, which the API maps to **`404`**. Anyone other than the invitee, including the inviting admin, gets `404`, the same answer as an unknown id. A second accept also gets `404`.
- After acceptance the membership is `active` and grants its role (and branch scope) like any other membership.
- The web app shows a "Pending invitations" list with Accept.

**Expiry** of pending invitations is **not specified** in the fix contract. Today an invitation stays pending until it is accepted.

## Branch-scoped write rules (M1)

_(PR #1 fix contract; API-only in this round.)_ Review finding M1: the API and RLS combined _the union of the user's roles_ with _the union of their branches_. For example, `billing` at Main plus `nurse` at East allowed writing patients at Main.

- **Writes are evaluated per (role, branch) pair in the API.** A patient may be created (or, once an update endpoint exists, updated) at branch _X_ only if the caller has an **active** membership with a writer role (`tenant_admin`, `doctor`, `nurse`, `receptionist`) whose `branch_id` is _X_ or `NULL` (all branches).
  - This is checked with `ITenantContext.HasRoleAtBranch(branchId, roles)` in patient create. A missing writer role at that branch gets `403`.
  - There is no patient update endpoint yet. A future one must call `PatientEndpoints.CanWritePatientAt`.
- **The database does not enforce this yet.** RLS still checks role and branch separately (`has_tenant_role` + `can_access_branch`). Per-branch RLS (`has_branch_role`) is a deferred known gap, so any path that writes to `patient.patients` without going through the API is not covered.
- **Reads stay tenant-wide** for the registry read roles. A branch-scoped clinician can read every patient of the tenant (CEO product decision).
- **`tenant_admin` is always tenant-wide** (CEO product decision). The API rejects adding a `tenant_admin` with a branch with `400`. A matching DB `CHECK (role <> 'tenant_admin' or branch_id is null)` is part of the deferred DB hardening unless the DB team ships it with B1.
- Branch scoping of non-patient modules will be designed with those modules.

## Server-owned fields (M2)

_(PR #1 fix contract; API-only in this round.)_ `id`, `tenant_id`, `created_at`, `created_by`, `updated_at`, `updated_by` and `deleted_at` (on create) are **server-owned in the API**. Values a client sends for them through the API are ignored:
- API request DTOs have no such properties.
- `TenantSaveChangesInterceptor` sets the tenant and actor.
- A forged `created_by` / `deleted_at` sent to the API therefore never sticks.

**The database does not enforce this yet.** The `authenticated` role still has the insert column grants on the audit columns, and the trigger keeps a client-supplied `created_by` (`coalesce(new.created_by, auth.uid())`). A direct table write (for example through PostgREST, if the schema is exposed, or a future code path) can still forge attribution or insert a soft-deleted row. This is a deferred known gap.

Patient contact fields are capped server-side at 32 characters (phone) and 254 (email). MRNs are upper-cased by the API.

Patient search is `POST /api/v1/patients/search` with the term in the JSON body, so names and MRNs never appear in URLs or access logs. `GET /api/v1/patients?search=` returns `400`.

## Tenant switch and sign-out in the browser (M3)

_(PR #1 fix contract.)_ The active context is stored **per user**, not per browser session. A switch made in one tab or device therefore changes the tenant of the user's other sessions at their next token refresh, or at their next API call if the token has no tenant claim.
- Every API response carries `X-Hms-Tenant: <resolved tenant id>`.
- The web app compares the tenant the server resolved (the `tenant_id` of every `TOKEN_REFRESHED` token, including ones broadcast from other tabs, and `X-Hms-Tenant`) with the tenant it displays. On a mismatch it calls `queryClient.clear()` and shows a "hospital changed" banner.
  - The banner is `role="alert"`, `data-testid="tenant-switched-banner"` (CTO frontend notes). Its wording is not part of the contract.
- `queryClient.clear()` also runs on every explicit tenant switch and on `SIGNED_OUT` from **any** tab, so no PHI stays in memory after sign-out.
- The Supabase session lives in `sessionStorage` (per tab; review Minor 3, Web fix branch), so a new tab starts signed out unless it is opened from a signed-in tab (`window.open`, which copies sessionStorage).
  - Such tabs share one refresh token, so a tab can be signed out after another tab refreshes. That is expected; the user signs in again.
  - The tenant-changed check therefore does not promise that another tab immediately shows the new hospital's data. It only promises that the old data is cleared and the banner is shown.

## Auditing

- `audit.stamp_audit_columns()` maintains `created_at/by` and `updated_at/by`. `created_*` cannot be changed after insert. On UPDATE the actor comes from `auth.uid()`. On INSERT a client-supplied `created_by` is currently **kept** (`coalesce(new.created_by, auth.uid())`). The API never sends a client value, but direct table writes can (deferred known gap, see [Server-owned fields](#server-owned-fields-m2)).
- `audit.log_row_change()` writes INSERT/UPDATE/DELETE snapshots, tagged with the tenant and actor, for tenants, branches, memberships and patients.
- The audit log is append-only. UPDATE, DELETE and TRUNCATE are blocked by triggers, even for the owner.

## Verified by tests

- `supabase/tests/*.sql`: 103 assertions in 7 files. They cover cross-tenant read, search, update, delete and insert, privilege escalation, moving rows between tenants, anon access, outsiders, suspended tenants, forged tenant claims, branch scope, constraints, audit visibility and immutability, **the access token hook** (privileges, output, forged claims stripped), **context switching**, **add_member**, and **the `hms_api` role** (no direct privileges, denied without a role switch, RLS via claims).
- `Hms.IntegrationTests` (real Postgres, real JWT validation with test-signed ES256 tokens + fake JWKS): JWT negative cases, spoofed headers/body/app_metadata ignored, a token tenant without a membership gets 403, another tenant's patient/branch/member id gets 404, context switch validation, branch/member admin endpoints and roles, duplicate MRN 409, suspended members lose access.
- `Hms.DatabaseTests`: RLS defense in depth as `hms_api_login` (filter bypassed, wrong app tenant, forged session tenant, cross-tenant insert, no transaction, role escalation, row_security off, hook execution).
- Playwright E2E: sign-in through mock GoTrue + the real hook, tenant/branch switching, patient registration, admin pages, and cross-tenant attacks through the running gateway (foreign ids, spoofed headers, tampered/unsigned tokens).
- `Hms.UnitTests`: claim parsing, middleware fallback rules, DB session claims JSON, JWT option rules, validators, fail-closed tenant context, EF filter and interceptor isolation.
- **PR #1 regression tests** (written against the fix contract; red until the fix branches merge):
  - `backend/tests/Hms.IntegrationTests/Pr1Regression/` (`Category=Database`, real API pipeline as `hms_api_login`). These complement Backend's own invitation and M1 tests in `TenantAdminApiTests` / `TenantIsolationApiTests`.
    - `B1MembershipConsentApiTests`: identical 202 in every case, no default-tenant change (hook, `/me`, persisted profile), no access while invited, accept only by the invitee, pending invites immutable and hidden from admins.
    - `M1BranchScopedWriteApiTests`: role bound to the branch in the **API**, tenant-wide reads, `tenant_admin` + branch gives `400`.
    - `M2ServerOwnedFieldsApiTests`: forged audit fields sent through the API are ignored.
    - `M3TenantHeaderApiTests`: `X-Hms-Tenant`.
  - Playwright:
    - `tests/playwright/e2e/m3-tenant-switch-cache.spec.ts`: with two tabs, a switch in one leaves no pre-switch cache in the other and shows the banner; sign-out clears the query cache and web storage in every tab.
    - `admin.spec.ts`: invite → pending/hidden → accept → suspend, with the uniform message.
    - `patients.spec.ts`: POST search, and `GET ?search=` returns `400`.
  - The SQL-level tests for the B1 invite fix belong to the database team (`supabase/tests/`).

## Known gaps / backlog

| # | Gap | Plan |
|---|---|---|
| S1 | ~~JWT signature validation unverified~~ | **Closed (Sprint 1):** JWKS + tests with signed tokens. Not yet exercised against tokens from the hosted project (no deployed API). |
| S2 | ~~API connects as table owner~~ | **Closed (Sprint 1):** `hms_api`/`hms_api_login` + per-transaction role and claims. The hosted `hms_api_login` must be created out-of-band (see Sprint 1 report). |
| S3 | ~~No access token hook~~ | **Function shipped (Sprint 1).** It must be **enabled in the Auth dashboard** (manual step, see [auth-flow.md](auth-flow.md)). |
| S4 | Audit rows hold full row snapshots (PHI) | Review minimisation/retention. Access is restricted to tenant_admin. |
| S5 | **Deferred (PR #1 scope change):** RLS is not `FORCE`d (`FORCE ROW LEVEL SECURITY` not set; the table owner bypasses RLS). | The API no longer uses the owner. Migrations and admin scripts still do, by design. Add `alter table … force row level security` plus a guardrail test in a later DB hardening round. |
| S6 | No CSP header yet | Sprint 4 once the origins are known |
| S7 | Rate limiting is in-memory per instance | Fine for a single free instance. Revisit when scaling. |
| S8 | Hook claims (`branch_ids`, `hms_roles`) can be up to one token lifetime stale | The API and RLS re-check memberships on every request. Claims are hints only. |
| S9 | `add_member` requires an existing account (no email invitations yet) | The PR #1 fix makes memberships consent-based (`invited` → accept). No email is actually sent yet, and invitations for people without an account still need the Supabase Auth admin API (server-side only). Sprint 2+. |
| S10 | `hms_api_login` can act as any user (trust model, review Minor 1) | Documented above. The hosted secret, network restriction and `CONNECTION LIMIT` must be in place before the API is deployed against the hosted project. |
| S13 | **Deferred (PR #1 scope change, M2 DB side):** the database does not stop direct writes to audit fields. `authenticated` keeps insert grants on `created_at/created_by/updated_at/updated_by/deleted_at`, and the trigger keeps a client-supplied `created_by`. | Enforced in the API only for now. Later DB hardening: actor-wins trigger (`created_by := coalesce(auth.uid(), …)`), revoke the column grants, EF stops sending audit columns. |
| S14 | **Deferred (PR #1 scope change, M1 DB side):** no `has_branch_role`-based RLS for branch-scoped writes. RLS checks role and branch separately, so a direct table write by a user with a writer role at one branch can still write at another. | Enforced in the API only for now (`HasRoleAtBranch`). Later DB hardening: `identity.has_branch_role(tenant, branch, roles[])` in the `patients` INSERT/UPDATE policies, plus the `tenant_admin` tenant-wide `CHECK`. |
| S11 | **MFA not enforced (backlog, not in Sprint 1)** | Tenant admins should be required to use MFA (`aal2`). The API does not check the `aal` / `amr` claims today. Planned approach: Supabase Auth MFA (TOTP) enrolment and a step-up challenge in the web app; the API (and optionally RLS through `auth.jwt() ->> 'aal'`) requires `aal = 'aal2'` for `tenant_admin` operations. Scheduled for a later sprint; no date committed. |
| S12 | Pending invitations never expire, and admins cannot list or revoke them | Backlog (contract update 21:16 IST). Expiry is not specified. |
