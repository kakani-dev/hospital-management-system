# Multi-tenancy & security design

_Owners (simulated): Security Team, Database Engineering Team. Status: Sprint 0._

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

1. The JWT bearer handler validates the Supabase token. *(TODO Sprint 1: JWKS validation against a real project.)*
2. `ClaimsTenantResolver` reads `sub`, plus `tenant_id`/`branch_id` from either a top-level claim (custom access token hook) or `app_metadata`. Users cannot edit `app_metadata`. `user_metadata`, headers, query strings and bodies are **ignored**.
3. `EfMembershipStore` confirms an **active** membership in an **active** tenant. If a branch is pinned, it must be inside the user's branch scope.
4. `TenantContext` (scoped) is filled in. `.RequireTenant()` endpoints return **403** when it is not resolved.
5. `PatientsDbContext` applies `TenantId == resolved tenant && DeletedAt == null` as a global query filter.
6. `TenantSaveChangesInterceptor` overwrites `TenantId` on insert, blocks `TenantId` changes, and throws if no tenant is resolved.

### Database (RLS)

Helper functions in `identity` are `SECURITY DEFINER` with `search_path = ''`, and they only answer questions about `auth.uid()`:

- `identity.current_tenant_ids()`: active memberships in active tenants, intersected with the optional `app_metadata.tenant_id` pin
- `identity.has_tenant_role(tenant, roles[])`
- `identity.current_branch_ids(tenant)` / `identity.can_access_branch(tenant, branch)`
- `identity.shares_tenant_with(user)`

Policy summary:

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| tenants | members | — (service role) | tenant_admin; only `name` and `settings` (column grant) | — |
| branches | members | tenant_admin | tenant_admin | tenant_admin |
| user_profiles | self + colleagues | — | self; only `display_name` | — |
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

- `supabase/tests/*.sql`: 67 assertions. They cover cross-tenant read, search, update, delete and insert, privilege escalation, moving rows between tenants, anon access, outsiders, suspended tenants, forged tenant claims, branch scope, constraints, and audit visibility and immutability.
- `Hms.IntegrationTests`: spoofed `X-Tenant-Id` header ignored, `tenantId` in the request body ignored, a token for a tenant without a membership gets 403, another tenant's patient by id gets 404, cross-tenant branch gets 403, role and branch checks.
- `Hms.UnitTests`: claim parsing edge cases, fail-closed tenant context, EF filter and interceptor isolation.

## Known gaps (tracked)

| # | Gap | Plan |
|---|---|---|
| S1 | Supabase JWT signature validation is not verified against a real project | Sprint 1: JWKS config + integration test with signed tokens |
| S2 | The API connects to Postgres as the table owner, so RLS does not apply to API queries. Isolation there depends on the EF filters and checks. | Sprint 1: dedicated non-owner DB role. Set `request.jwt.claims` per transaction so RLS also covers API traffic. |
| S3 | No custom access token hook yet to issue `tenant_id`/`branch_id` claims | Sprint 1 |
| S4 | Audit rows hold full row snapshots (PHI) | Review minimisation/retention. Access is restricted to tenant_admin. |
| S5 | RLS is not `FORCE`d (owner bypass) | Revisit with S2 |
| S6 | No CSP header yet | Sprint 4 once the origins are known |
| S7 | Rate limiting is in-memory per instance | Fine for a single free instance. Revisit when scaling. |
