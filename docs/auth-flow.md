# Authentication & tenant context flow (Sprint 1)

_Owners (simulated): Security Team, React Team, Database Engineering._

## Components

| Piece | Where | Role |
|---|---|---|
| Supabase Auth (GoTrue) | hosted project `gvgomzogbzbjhlcsimrx` (locally: `tests/mock-auth`) | Email/password sign-in for people who already have a password; verifies the magic-link token hash minted for a new invitee |
| Custom access token hook | `identity.custom_access_token_hook(event jsonb)` | Adds `tenant_id`, `branch_id`, `branch_ids`, `hms_roles` claims from memberships |
| SPA auth | `apps/web/src/lib/supabase.ts`, `features/auth/AuthProvider.tsx` | `supabase-js` session; protected routes; sign-out |
| Gateway JWT validation | `backend/gateway/Hms.Gateway/Infrastructure/AuthenticationSetup.cs` | JWKS (ES256/RS256) + optional HS256 legacy secret; issuer/audience/lifetime checks |
| Tenant resolution | `Hms.Modules.Identity.Tenancy.TenantResolutionMiddleware` | Verifies the claimed (or stored default) tenant against active memberships |
| DB session | `Hms.SharedKernel.Persistence.RlsTransactionInterceptor` | Each transaction runs `SET LOCAL ROLE authenticated` + `request.jwt.claims` so RLS applies |

## Sign-in

```mermaid
sequenceDiagram
  participant U as Browser (SPA)
  participant A as Supabase Auth
  participant H as identity.custom_access_token_hook
  participant G as HMS API (gateway)
  participant P as PostgreSQL (RLS)
  U->>A: POST /auth/v1/token?grant_type=password (email, password)
  A->>H: event {user_id, claims}
  H-->>A: claims + tenant_id, branch_ids, hms_roles (forged values stripped)
  A-->>U: access_token (ES256, kid) + refresh_token
  U->>G: GET /api/v1/me  Authorization: Bearer <token>
  G->>A: GET /auth/v1/.well-known/jwks.json (cached; refreshed on unknown kid)
  G->>G: validate signature, iss = <url>/auth/v1, aud = authenticated, exp, role = authenticated
  G->>P: BEGIN; set_config('role','authenticated',true); set_config('request.jwt.claims', …, true)
  G->>P: membership check + queries (RLS-scoped)
  P-->>G: rows for the user's tenant only
  G-->>U: memberships, active tenant/branch, roles, accessible branches
```

- The SPA uses only the **publishable/anon key** (`VITE_SUPABASE_PUBLISHABLE_KEY` or `VITE_SUPABASE_ANON_KEY`). Service-role/secret keys never go into `VITE_*` variables.

## Invite sign-in (no password yet)

Issuing an invite writes `identity.invite_links` only. It does not create `auth.users` and it does not set a password.

1. The invite email (template `invite_link`, or `signup_approved` for the first hospital admin) contains `https://medicore-hms-three.vercel.app/invite/<token>` from `Email:PublicBaseUrl`.
2. `/invite/:token` is anonymous. **Email me a sign-in code** calls `POST /api/v1/public/invites/{token}/sign-in-code`. Identity queues a six-digit code through the SMTP outbox.
3. The invitee opens the link in the email (`#code=` is filled in) or types the code. `POST /api/v1/public/invites/{token}/sign-in` checks the hash. Identity then calls GoTrue admin (`Auth:Supabase:ServiceRoleKey`, identity container only) and returns `{tokenHash, verificationType: "magiclink"}`.
4. The SPA calls `supabase.auth.verifyOtp({ token_hash, type: 'magiclink' })`. The API accepts that session because it is a normal GoTrue JWT.
5. `user_metadata.needs_password` is true, so the page asks the invitee to choose a password (`supabase.auth.updateUser`) before **Join**. The password is never emailed.
6. **I already have a password** goes to `/login`, which is still `POST /auth/v1/token?grant_type=password`.

Playwright keeps the password path: those specs insert `auth.users` first. The code path is covered by SQL test 32, the email unit tests, and the invite page test. Mock auth does not implement the GoTrue admin API.
- The API client asks `supabase.auth.getSession()` for the current (auto-refreshed) token on every request and **never sends a tenant header**.
- Protected routes (`RequireAuth`) redirect to `/login`; after sign-in the user returns to the page they asked for.
- Sign-out calls `supabase.auth.signOut()` and clears every cached query.

## JWT validation rules (gateway)

| Check | Value |
|---|---|
| Signing keys | `<ProjectUrl>/auth/v1/.well-known/jwks.json` via `ConfigurationManager` (1 h refresh, 1 min minimum on unknown `kid`) |
| Algorithms | ES256, RS256; **HS256 only if `Auth:Supabase:LegacyJwtSecret` is set** |
| Issuer | `<ProjectUrl>/auth/v1` |
| Audience | `authenticated` |
| Lifetime | required `exp`, 30 s clock skew |
| Role | `role` claim must be `authenticated` (anon/service_role keys are rejected); `sub` must be a UUID |
| Unconfigured | empty `ProjectUrl` → every token rejected (fail closed) |
| HTTP JWKS | only with `AllowInsecureHttp=true` (local mock/tests); refused in `Production` |

Configuration: `Auth__Supabase__ProjectUrl`, `Auth__Supabase__Audience` (default `authenticated`), `Auth__Supabase__LegacyJwtSecret` (secret store only), `Auth__Supabase__AllowInsecureHttp`.

## Tenant / branch selection and switching

1. The **hook** picks the active tenant: the user's stored preference (`identity.user_profiles.active_tenant_id`) if they still hold an active membership there, otherwise their first membership (by tenant name). `branch_id` is only emitted when the stored branch is still accessible. `branch_ids` and `hms_roles` are informational; **the API always re-checks memberships in the database**.
2. If a token has **no** `tenant_id` claim (e.g. the hook isn't enabled yet), the API asks `identity.my_active_context()` for the same server-side default. A token that **does** carry a tenant the user isn't an active member of gets 403. It never silently falls back.
3. To switch, the SPA calls `POST /api/v1/me/context {tenantId, branchId?}`. `identity.set_active_context` validates the membership and branch scope (403/`42501` otherwise) and stores the choice. The SPA then calls `supabase.auth.refreshSession()` so the hook issues a token for the new tenant, and drops all cached tenant data.
4. Spoofed headers (`X-Tenant-Id`, …), body fields (`tenantId`) and `user_metadata` are ignored everywhere.

## Enabling the hook on the hosted project (manual dashboard step)

The function and its grants are created by migration `20261007090000_auth_context_and_api_role.sql`. Enabling it is a dashboard setting:

**Supabase Dashboard → project `gvgomzogbzbjhlcsimrx` → Authentication → Hooks → "Customize Access Token (JWT) Claims" → Add hook → Hook type: Postgres → Schema: `identity` → Function: `custom_access_token_hook` → Save / Enable.**

Until it's enabled, tokens carry no `tenant_id`, and the API uses the stored or default context (step 2). Everything still works, but switching tenants then depends on the server-side stored context rather than the token.

## Local and test setups

- **Integration tests** (`Hms.IntegrationTests`): tokens signed with a throwaway ES256 key, served by a fake JWKS `HttpMessageHandler`. They cover negative cases: expired, wrong issuer/audience, wrong key with a known kid, `alg: none`, HS256 without a secret, and anon/service_role roles.
- **E2E** (`tests/playwright`): `tests/mock-auth/server.mjs` implements the GoTrue endpoints the SPA uses and issues ES256 tokens whose claims come from the **real hook** (run as `supabase_auth_admin`). The API validates them through the mock's JWKS (`AllowInsecureHttp=true`, local only).
