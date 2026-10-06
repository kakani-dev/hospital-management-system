# API (v1)

The live contract is the OpenAPI document at `/openapi/v1.json`, with Swagger UI at `/swagger` (Development). Auth flow details: [auth-flow.md](auth-flow.md).

| Method | Path | Auth | Description |
|---|---|---|---|
| GET | `/health/live` | anonymous | Liveness (process only) |
| GET | `/health/ready` | anonymous | Readiness (includes the database, as the API role) |
| GET | `/api/v1/me` | JWT | Current user, server-resolved active tenant/branch, roles, accessible branches, **all** memberships (drives the switcher) |
| POST | `/api/v1/me/context` | JWT | `{tenantId, branchId?}`: validated against memberships in the DB (403 otherwise) and stored. Refresh the session afterwards to get a token for the new tenant. 204 on success. |
| GET | `/api/v1/tenants/current` | JWT + tenant | The resolved tenant, active branch and the caller's roles |
| GET | `/api/v1/branches` | JWT + tenant | Branches of the current tenant. Admins also see inactive ones. |
| POST | `/api/v1/branches` | tenant_admin | `{code, name, timezone}`: code `^[a-z0-9][a-z0-9-]{1,39}$`, IANA timezone. 409 on duplicate code. |
| PATCH | `/api/v1/branches/{id}` | tenant_admin | `{name?, timezone?, isActive?}`. Another tenant's id gives 404. |
| GET | `/api/v1/members` | tenant_admin | Memberships of the current tenant (including suspended), with email and branch |
| POST | `/api/v1/members` | tenant_admin | `{email, role, branchId?}`: adds an existing account (404 if no such user, 409 if a duplicate, 400 if the branch belongs to another tenant) |
| PATCH | `/api/v1/members/{id}` | tenant_admin | `{role?, status? (active/suspended)}`. You can't change your own membership (409). |
| GET | `/api/v1/patients?search=&page=&pageSize=` | admin/doctor/nurse/receptionist/billing | Paged patient list for the resolved tenant (`totalCount`) |
| GET | `/api/v1/patients/{id}` | same | Returns 404 for other tenants' ids |
| POST | `/api/v1/patients` | admin/doctor/nurse/receptionist | Registers a patient. Any `tenantId` in the body is ignored. `registeredBranchId` must be in the caller's branch scope. MRN is unique per tenant (409). |

Errors use RFC 7807 problem details: 400 validation, 401 unauthenticated or invalid token, 403 no membership/role/branch (or rejected by RLS), 404, 409 conflict, 429 rate limited.

**Tenant selection.** There is no tenant header. The tenant comes from the validated token's `tenant_id` claim (set by the access token hook), or from the server-side stored context when the token has none. Either way it must match an active membership, and PostgreSQL RLS enforces the same rule again for every query.
