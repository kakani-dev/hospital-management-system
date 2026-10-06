# API (v1)

The live contract is the OpenAPI document at `/openapi/v1.json`, with Swagger UI at `/swagger`. It is enabled in Development.

| Method | Path | Auth | Description |
|---|---|---|---|
| GET | `/health/live` | anonymous | Liveness (process only) |
| GET | `/health/ready` | anonymous | Readiness (includes the database) |
| GET | `/api/v1/me` | JWT | Current user, active tenant/branch, memberships loaded from the DB |
| GET | `/api/v1/tenants/current` | JWT + tenant | The resolved tenant and the caller's roles |
| GET | `/api/v1/patients?search=&page=&pageSize=` | JWT + tenant; admin/doctor/nurse/receptionist/billing | Paged patient list for the resolved tenant |
| GET | `/api/v1/patients/{id}` | same | Returns 404 for other tenants' ids |
| POST | `/api/v1/patients` | JWT + tenant; admin/doctor/nurse/receptionist | Register a patient. Any `tenantId` in the body is ignored. `registeredBranchId` must be in the caller's branch scope. |

Errors use RFC 7807 problem details: 400 validation, 401 unauthenticated, 403 no membership/role/branch, 404, 409 duplicate MRN, 429 rate limited.

**Tenant selection.** There is no tenant header. The tenant comes from the token (`tenant_id` claim or `app_metadata.tenant_id`) and must match an active membership.
