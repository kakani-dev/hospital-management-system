# Multi-tenancy & security design

_Owners (simulated): Security Team, Database Engineering Team. Status: Sprint 1._

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

### Database (RLS)

Helper functions in `identity` are `SECURITY DEFINER` with `search_path = ''`, and they only answer questions about `auth.uid()`:

- `identity.current_tenant_ids()`: active memberships in active tenants, intersected with the optional `app_metadata.tenant_id` pin
- `identity.has_tenant_role(tenant, roles[])`
- `identity.current_branch_ids(tenant)` / `identity.can_access_branch(tenant, branch)`
- `identity.shares_tenant_with(user)` / `identity.is_admin_of_member(user)`
- `identity.active_tenant_claim()`: the top-level `tenant_id` claim (hook), falling back to `app_metadata.tenant_id`

Definer functions callable by `authenticated` (each validates against memberships and raises `42501` otherwise): `identity.my_memberships()`, `identity.my_active_context()`, `identity.set_active_context(tenant, branch)` and `identity.add_member(tenant, email, role, branch)` (tenant_admin only). The hook function `identity.custom_access_token_hook` is executable **only** by `supabase_auth_admin`.

Policy summary:

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| tenants | members | — (service role) | tenant_admin; only `name` and `settings` (column grant) | — |
| branches | members | tenant_admin | tenant_admin | tenant_admin |
| user_profiles | self + active colleagues + (tenant_admin) any member of their tenant | — | self; only `display_name` | — |
| memberships | own + tenant_admin | tenant_admin | tenant_admin | tenant_admin |
| patients | admin, doctor, nurse, receptionist, billing | admin, doctor, nurse, receptionist, **at an accessible branch** | same, and branch rule on the new row; `tenant_id` not updatable | — (soft delete only) |
| audit_log | tenant_admin | — (trigger only) | — (blocked by trigger) | — (blocked by trigger) |

`anon` has no privileges on any HMS schema.

## Roles

`tenant_admin, doctor, nurse, receptionist, billing, pharmacist, lab_technician, viewer`. These are enforced by a CHECK constraint and mirrored in `HmsRoles`. `lab_technician`, `pharmacist` and `viewer` have no access to the patient registry yet. Their access will be designed with their modules.

## Auditing

- `audit.stamp_audit_columns()` maintains `created_at/by` and `updated_at/by`. The actor comes from `auth.uid()`, and `created_*` cannot be changed.
- `audit.log_row_change()` writes INSERT/UPDATE/DELETE snapshots, tagged with the tenant and actor, for tenants, branches, memberships and patients.
- The audit log is append-only. UPDATE, DELETE and TRUNCATE are blocked by triggers, even for the owner.

## Verified by tests

- `supabase/tests/*.sql`: 103 assertions in 7 files. They cover cross-tenant read, search, update, delete and insert, privilege escalation, moving rows between tenants, anon access, outsiders, suspended tenants, forged tenant claims, branch scope, constraints, audit visibility and immutability, **the access token hook** (privileges, output, forged claims stripped), **context switching**, **add_member**, and **the `hms_api` role** (no direct privileges, denied without a role switch, RLS via claims).
- `Hms.IntegrationTests` (real Postgres, real JWT validation with test-signed ES256 tokens + fake JWKS): JWT negative cases, spoofed headers/body/app_metadata ignored, a token tenant without a membership gets 403, another tenant's patient/branch/member id gets 404, context switch validation, branch/member admin endpoints and roles, duplicate MRN 409, suspended members lose access.
- `Hms.DatabaseTests`: RLS defense in depth as `hms_api_login` (filter bypassed, wrong app tenant, forged session tenant, cross-tenant insert, no transaction, role escalation, row_security off, hook execution).
- Playwright E2E: sign-in through mock GoTrue + the real hook, tenant/branch switching, patient registration, admin pages, and cross-tenant attacks through the running gateway (foreign ids, spoofed headers, tampered/unsigned tokens).
- `Hms.UnitTests`: claim parsing, middleware fallback rules, DB session claims JSON, JWT option rules, validators, fail-closed tenant context, EF filter and interceptor isolation.

## Known gaps (tracked)

| # | Gap | Plan |
|---|---|---|
| S1 | ~~JWT signature validation unverified~~ | **Closed (Sprint 1):** JWKS + tests with signed tokens. Not yet exercised against tokens from the hosted project (no deployed API). |
| S2 | ~~API connects as table owner~~ | **Closed (Sprint 1):** `hms_api`/`hms_api_login` + per-transaction role and claims. The hosted `hms_api_login` must be created out-of-band (see Sprint 1 report). |
| S3 | ~~No access token hook~~ | **Function shipped (Sprint 1).** It must be **enabled in the Auth dashboard** (manual step, see [auth-flow.md](auth-flow.md)). |
| S4 | Audit rows hold full row snapshots (PHI) | Review minimisation/retention. Access is restricted to tenant_admin. |
| S5 | RLS is not `FORCE`d (owner bypass) | The API no longer uses the owner. Migrations and admin scripts still do, by design. |
| S6 | No CSP header yet | Sprint 4 once the origins are known |
| S7 | Rate limiting is in-memory per instance | Fine for a single free instance. Revisit when scaling. |
| S8 | Hook claims (`branch_ids`, `hms_roles`) can be up to one token lifetime stale | The API and RLS re-check memberships on every request. Claims are hints only. |
| S9 | `add_member` requires an existing account (no email invitations yet) | Sprint 2+: invitation flow through Supabase Auth admin API (server-side only) |
