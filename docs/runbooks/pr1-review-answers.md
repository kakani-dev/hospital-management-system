# PR #1 review: DevOps & Release answers (Q3, Q5, Q6, Minor 9)

| | |
|---|---|
| Review | `/workspace/review-pr1/REVIEW.md` (PR #1 "Sprint 1: identity/tenancy/auth + patient registration", `feat/sprint-1-identity` → `main`, head `f756f20`) |
| Fix plan | `/workspace/review-pr1/FIX-PLAN.md`. Owner here: DevOps & Release, branch `fix/pr1-devops` (cut from `f756f20`) |
| Written | 2026-10-06 ~21:20 IST |
| Rules followed | Nothing pushed. GitHub, hosted Supabase `medicore-hms` (`gvgomzogbzbjhlcsimrx`) and Render were used **read-only**. No settings, roles, passwords, network rules, branch protection or rulesets were changed. No secret values appear in this document. |

Legend: **[NEEDS MOHITH'S APPROVAL]** = a change outside the repo that only Mohith may apply. **[NOT VERIFIED]** = couldn't be read or run from here; the reason is given.

---

## Q3. Required status checks on `main`

> 3. Are the `database` and `e2e` jobs **required** status checks under main's branch protection?

### Finding

**No. `main` has no branch protection and no rulesets, so no status check is required.** On this plan the repo **can't have any** until either the plan or the repo visibility changes.

### Evidence (gh CLI, read-only, 2026-10-06 ~21:10 IST)

Repo from `git remote -v`: `https://github.com/kakani-dev/hospital-management-system.git`. The default `gh` account (`kakani17481a0566`) gets `404` on this private repo, so I switched to the already-logged-in owner account `kakani-dev` (`admin: true`) for these reads and then switched back.

| Call | Result (verbatim) |
|---|---|
| `gh api repos/kakani-dev/hospital-management-system` | `"private":true,"visibility":"private","default_branch":"main"`, permissions `admin:true` |
| `gh api repos/kakani-dev/hospital-management-system/branches/main` | `"protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}` |
| `gh api …/branches/main/protection` | **HTTP 403** `"Upgrade to GitHub Pro or make this repository public to enable this feature."` |
| `gh api …/branches/main/protection/required_status_checks` | **HTTP 403**, same message |
| `gh api …/rules/branches/main` | **HTTP 403**, same message |
| `gh api "…/rulesets?includes_parents=true"` | **HTTP 403**, same message |

**Current required checks: none** (`"contexts":[]`, `"checks":[]`, `enforcement_level: "off"`).

The 403 isn't a permissions problem: the token is the repo admin. Branch protection and rulesets on **private** repos need GitHub Pro, Team or Enterprise, and the owner account is on GitHub Free (Supabase org also `free`, for context).

**Check names.** Each check-run name is the job's `name:` in `.github/workflows/ci.yml`. All are emitted by GitHub Actions, `app_id` **15368**.

| Job id | Check context (exact) | PR #1 head `f756f20`, run 37485120738 |
|---|---|---|
| `web` | `Frontend (lint, unit tests, build)` | success (20:40:15 → 20:40:53 IST) |
| `api` | `Backend (build + unit tests)` | success (20:40:14 → 20:41:00 IST) |
| `database` | `SQL/RLS tests + API integration tests (real Postgres)` | success (20:40:15 → 20:41:46 IST) |
| `e2e` | `Playwright E2E (web + API + mock auth + Postgres)` | success (20:40:15 → 20:42:33 IST) |
| `db-supabase-prototype` (new on this branch) | `DB prototype on Supabase stack (supabase start, non-required)` | not run yet. **Must not be required** (see Minor 9) |

Other things on that commit:
- Commit statuses (legacy API) are empty (`contexts: []`).
- A `vercel` check suite exists with no conclusion. It isn't a CI job and shouldn't be required.
- `cleanup.yml` only has `schedule`/`workflow_dispatch` triggers, so it never reports on PRs.

### Recommendation / next action [NEEDS MOHITH'S APPROVAL]

Before branch protection can exist, Mohith must pick one:

1. **Upgrade the `kakani-dev` account to GitHub Pro.** This is a paid purchase. Recommended: smallest change, and the repo stays private.
2. Move the repo into an organization on GitHub Team.
3. Make the repo public. **Not recommended** for a hospital system, even with synthetic data, because it exposes the security design and infra notes.

After that, require all four existing CI checks, including `database` and `e2e`. Do **not** require the prototype or `vercel`. Two equivalent ways follow. **Neither has been run.**

**Option A: classic branch protection.** `PUT` replaces the whole protection object. None exists today, so nothing is lost.

```bash
gh api -X PUT repos/kakani-dev/hospital-management-system/branches/main/protection \
  -H "Accept: application/vnd.github+json" --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      { "context": "Frontend (lint, unit tests, build)", "app_id": 15368 },
      { "context": "Backend (build + unit tests)", "app_id": 15368 },
      { "context": "SQL/RLS tests + API integration tests (real Postgres)", "app_id": 15368 },
      { "context": "Playwright E2E (web + API + mock auth + Postgres)", "app_id": 15368 }
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
```

**Option B: repository ruleset.** This is GitHub's newer mechanism; use A or B, not both.

```bash
gh api -X POST repos/kakani-dev/hospital-management-system/rulesets \
  -H "Accept: application/vnd.github+json" --input - <<'JSON'
{
  "name": "main: required CI",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "Frontend (lint, unit tests, build)", "integration_id": 15368 },
          { "context": "Backend (build + unit tests)", "integration_id": 15368 },
          { "context": "SQL/RLS tests + API integration tests (real Postgres)", "integration_id": 15368 },
          { "context": "Playwright E2E (web + API + mock auth + Postgres)", "integration_id": 15368 }
        ] } }
  ]
}
JSON
```

Notes:
- `enforce_admins: true` (or an empty `bypass_actors`) also stops Mohith from merging on red CI. If he wants an emergency bypass, set `enforce_admins` to `false`, or add himself as a bypass actor.
- `required_approving_review_count: 0` is intentional for a solo owner, because GitHub doesn't let you approve your own PR.
- Renaming any job's `name:` changes its check context. The required list must be updated in the same PR, or every PR will wait forever for a check that no longer exists.
- Verify afterwards (read-only): `gh api repos/kakani-dev/hospital-management-system/branches/main/protection/required_status_checks` or `gh api repos/kakani-dev/hospital-management-system/rules/branches/main`.

---

## Q5. JWT expiry and refresh-token reuse interval on hosted `medicore-hms`

> 5. What is the JWT expiry and refresh-token reuse interval on the hosted project? That determines how long a stale `tenant_id` claim (or a signed-out session) stays usable.

### Finding

**[NOT VERIFIED] I couldn't read the hosted values.** I'm not guessing them. These values live in Supabase Auth's config, which only the Management API (`GET /v1/projects/{ref}/config/auth`) or the Dashboard exposes. They aren't stored in Postgres. What's missing on this machine:

- No `SUPABASE_ACCESS_TOKEN` in the environment, and no repo `.env` that holds one.
- The `supabase` CLI isn't installed or logged in (no `~/.supabase` access token). The 2.119.0 binary I downloaded to `/tmp` for config validation isn't logged in, and I didn't log it in.
- The connected Supabase MCP integration has no auth-config tool. Its read-only calls worked: `get_project` → `medicore-hms`, region `ap-south-1`, Postgres `17.11.0.003`, `ACTIVE_HEALTHY`; organization plan `free`. But they can't return `jwt_exp` or `security_refresh_token_reuse_interval`.

**Repo comparison:** there is **no `supabase/config.toml` in the repo** (`git ls-files` shows none), so the repo doesn't pin these values. For reference only, these are **not** the hosted values:
- Supabase CLI 2.119.0 template defaults: `jwt_expiry = 3600`, `enable_refresh_token_rotation = true`, `refresh_token_reuse_interval = 10`.
- The new CI-only config `.github/supabase-ci/supabase/config.toml` (Minor 9) sets `jwt_expiry = 900`, rotation `true`, reuse interval `10`, for the throwaway CI stack only.

**How Mohith can read the hosted values (read-only, about 1 minute):**
- Dashboard → Project `medicore-hms` → Authentication → Sessions (refresh-token rotation and reuse interval), and the JWT settings page ("Access token expiry time"; under Project Settings → JWT Keys in current dashboards).
- Or, with a personal access token he already has:
  ```bash
  curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    https://api.supabase.com/v1/projects/gvgomzogbzbjhlcsimrx/config/auth \
  | jq '{jwt_exp, refresh_token_rotation_enabled, security_refresh_token_reuse_interval,
         sessions_timebox, sessions_inactivity_timeout, sessions_single_per_user}'
  ```

### What I could verify locally (evidence for the recommendation)

I ran the real Supabase Auth server, **GoTrue v2.197.0** (the version CLI 2.119.0 pins), against a throwaway PG 17.11 cluster with the repo's migrations and the hook enabled, using `.github/scripts/supabase-ci-hook-smoke.sh`. Results:

| Check | Result |
|---|---|
| `jwt_expiry = 900` honoured | `exp - iat = 900` ✓ |
| Hook stamps tenant claims on sign-in **and on every refresh** | `tenant_id = Alpha`, `hms_roles = ["receptionist"]` on both ✓ |
| Rotation | every refresh returns a new refresh token ✓ |
| Replaying the **parent** of the active refresh token, outside the interval | returns the *same* active token. This is Supabase's documented "lost response" allowance. ✓ |
| Replaying an **older** refresh token after the 10 s interval | rejected: HTTP 400 `refresh_token_already_used` ("Possible abuse attempt") ✓ |
| Does that reuse detection kill the session's newest refresh token? | **No.** In this local run the newest token still refreshed successfully. Supabase's docs say the whole session is revoked. The CI job prints this as `info` so a run on GitHub shows how the real stack behaves. Treat reuse detection as **not** a reliable session kill switch until that's confirmed. |

### Recommendation [NEEDS MOHITH'S APPROVAL to change hosted]

| Setting (Management API field) | Recommend | Why |
|---|---|---|
| `jwt_exp` | **900** (15 min). Acceptable range 900–1800. | Limits how long a stale `tenant_id`/`hms_roles` claim, or a stolen or signed-out access token, stays valid. Access tokens can't be revoked before `exp`. The API and RLS re-check memberships on every request anyway, so the claim is informational, but the PHI exposure window of a leaked token is still `jwt_exp`. supabase-js refreshes in the background, so users don't notice. |
| `refresh_token_rotation_enabled` | **true** | Each refresh token is single-use, which is the prerequisite for reuse detection. |
| `security_refresh_token_reuse_interval` | **10** (seconds) | This is Supabase's default and recommendation. Lower values log users out on multi-tab or SSR races. Higher values give a stolen refresh token a longer replay window. |
| `sessions_timebox` / `sessions_inactivity_timeout` | e.g. 12 h shift timebox / 30 min inactivity | HIPAA automatic logoff (§164.312(a)(2)(iii), review Minor 3). These are **Supabase Pro** features and the org is on Free. Until then, the Web team's client-side idle logoff (Minor 3) is the control. |

Change command for later. **Not run.** Changing it needs a Management API token, which this box doesn't have.
```bash
curl -s -X PATCH -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" \
  https://api.supabase.com/v1/projects/gvgomzogbzbjhlcsimrx/config/auth \
  -d '{"jwt_exp":900,"refresh_token_rotation_enabled":true,"security_refresh_token_reuse_interval":10}'
```
The new expiry applies only to tokens issued after the change, so existing tokens keep their old `exp`. Also confirm that `signOut({ scope: 'global' })` is used on shared ward workstations, because a local sign-out doesn't end other sessions.

---

## Q6. Restricting `hms_api_login` (secret + network)

> 6. When `hms_api_login` is created on hosted, how will its secret and network access be restricted (Minor 1)?

Minor 1 context: `hms_api_login` can act as any user in any tenant by setting `sub`/`tenant_id`. That makes it the same trust level as PostgREST's `authenticator`, so its credentials must be handled like `service_role`.

### Finding: current state

| Where | What |
|---|---|
| Repo definition | `supabase/migrations/20261007090000_auth_context_and_api_role.sql` §6 creates `hms_api` as `NOLOGIN NOINHERIT` with no table privileges, plus `grant authenticated to hms_api; grant anon to hms_api;`. Per its comment, `hms_api_login` is created **out-of-band**: `create role hms_api_login login noinherit password '<secret>'; grant hms_api to hms_api_login;` |
| Local/CI only | `supabase/scripts/local-api-login-role.sql` creates `hms_api_login` with a well-known, committed local-only password (throwaway DBs only). The same value is in `appsettings.json` (review nit: move it to Development), `docker-compose.yml`, CI and the Jenkinsfile. It must never be used on hosted. |
| API usage | `RlsTransactionInterceptor` runs `set_config('role', …, true)`, `request.jwt.claims` and `…claim.sub` per transaction, so everything is transaction-local and safe with Supavisor **transaction mode (:6543)**. `/health/ready` runs EF `CanConnect` as this login. |
| Render | `infra/render/render.yaml`: `hms-api`, `plan: free`, `region: singapore`, `ConnectionStrings__HmsDatabase` with `sync: false`, which means it's set in the dashboard and never committed. Render MCP (read-only): workspace "My Workspace" has **no services**, so nothing is deployed and there's no secret yet. |
| Hosted DB (read-only `SELECT`s via Supabase MCP) | `hms_api_login` **doesn't exist yet**. `hms_api` exists (`NOLOGIN`, `NOINHERIT`, not superuser, no BYPASSRLS, `rolconnlimit -1`). `max_connections = 60` (Nano/Micro). Server `statement_timeout = 120s` (config file). `idle_in_transaction_session_timeout = 0`, `idle_session_timeout = 0`, `password_encryption = scram-sha-256`, `ssl = on`. `authenticator` has `statement_timeout=8s`, `lock_timeout=8s`. 12 backends in use when checked. |

### Plan [NEEDS MOHITH'S APPROVAL for every hosted, Render or Supabase-settings step; nothing below was applied]

#### 1. Where the secret lives
- **Only** in Render → service `hms-api` → Environment → `ConnectionStrings__HmsDatabase`, a secret env var (`sync: false` in the blueprint). A Render *Secret File* isn't needed: ASP.NET reads the env var natively, and a file would need a code change.
- Never in git, `.env` files, CI variables, tickets, chat or shell history. GitHub Actions doesn't need it, because CI uses throwaway local databases.
- Store a copy only in Mohith's password manager. That's the break-glass copy.
- Render access = secret access. Keep the Render workspace to the minimum number of members, with 2FA on.
- Connection string shape (Supavisor transaction mode, IPv4, TLS verified):
  ```
  Host=<pooler host from Dashboard → Connect, e.g. aws-0-ap-south-1.pooler.supabase.com>;Port=6543;Database=postgres;
  Username=hms_api_login.gvgomzogbzbjhlcsimrx;Password=<secret>;SSL Mode=VerifyFull;Root Certificate=/app/certs/prod-ca-2021.crt;
  Maximum Pool Size=10;Timeout=15;Command Timeout=10;Max Auto Prepare=0
  ```
  For `VerifyFull`, the Supabase CA cert has to be in the image (Backend/DevOps follow-up). Until it is, use `SSL Mode=Require`.

#### 2. Least privilege (create the role, run once in **psql** as `postgres`, not the Dashboard SQL editor)
```sql
-- Read-only pre-checks
select rolname, rolcanlogin, rolinherit, rolconnlimit, rolconfig from pg_roles where rolname in ('hms_api','hms_api_login');
show max_connections;

-- Create: no superuser/createdb/createrole/replication/bypassrls, capped connections
create role hms_api_login login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls
  connection limit 20;
\password hms_api_login
-- \password prompts locally and sends only the SCRAM verifier, so the plaintext never reaches the
-- server log, pg_stat_statements or the dashboard query history (unlike ALTER ROLE ... PASSWORD '...').
grant hms_api to hms_api_login;   -- its ONLY membership (PG16+: INHERIT FALSE because the role is NOINHERIT, SET TRUE)

-- Per-login guards (apply at login and survive set_config('role','authenticated',true))
alter role hms_api_login set statement_timeout = '8s';                    -- same as PostgREST's authenticator
alter role hms_api_login set lock_timeout = '3s';
alter role hms_api_login set idle_in_transaction_session_timeout = '15s'; -- kills a leaked open transaction
-- Do NOT set idle_session_timeout: Supavisor keeps idle server connections pooled and reaps them itself.

-- Verify
select rolname, rolcanlogin, rolinherit, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication,
       rolconnlimit, rolconfig
from pg_roles where rolname = 'hms_api_login';
select r.rolname as member_of, m.inherit_option, m.set_option, m.admin_option
from pg_auth_members m join pg_roles r on r.oid = m.roleid
where m.member = 'hms_api_login'::regrole;   -- expect exactly: hms_api | f | t | f
```
Expected behaviour (already covered locally by `backend/tests/Hms.DatabaseTests`):
- A query without the per-transaction role switch → `42501` (fails closed).
- The login can't `SET ROLE service_role`, `postgres` or `supabase_auth_admin`, can't turn off `row_security`, and can't execute the hook.

The timeouts protect availability, not security: the login can still `SET` them per session.

Smoke test after creation, from an allow-listed IP:
```bash
psql "host=<pooler-host> port=6543 dbname=postgres user=hms_api_login.gvgomzogbzbjhlcsimrx sslmode=require" \
  -c "select current_user" -c "select count(*) from patient.patients"   # second query must fail with 42501
```

#### 3. Rotation procedure
Cadence: **every 90 days**, and immediately on suspected exposure, when someone with Render access leaves, or after a Render or Supabase security incident. Log the date and who did it in this runbook, never the value.

*Standard (single role; fine before go-live and on the free tiers):*
1. Generate a new secret locally in the password manager (≥ 32 random characters, URL-safe so it fits a connection string).
2. Render → `hms-api` → Environment → edit `ConnectionStrings__HmsDatabase` with the new password → **Save only** (no deploy yet).
3. In psql as `postgres`, run `\password hms_api_login` and enter the new secret. New connections with the old secret are refused from now on. Connections that are already authenticated, including Npgsql's and Supavisor's pooled ones, keep working.
4. Immediately: Render → Manual Deploy → *Deploy latest commit*. New instances start with the new secret.
5. Verify:
   - `GET /health/ready` returns 200 (EF CanConnect as `hms_api_login`).
   - One authenticated API call works.
   - Supabase Logs → Postgres show no new `password authentication failed for user "hms_api_login"` after the cutover.
   - `select count(*) from pg_stat_activity where usename = 'hms_api_login';` is > 0.
   - If Supavisor still rejects the new password, wait a minute for its auth cache to refresh and retry.
6. Revoke old: the old password is already invalid. To drop any server connections opened before the cutover:
   `select pg_terminate_backend(pid) from pg_stat_activity where usename = 'hms_api_login' and backend_start < '<cutover timestamp>';`

*Zero-downtime variant (use once real PHI and traffic exist):* alternate between two identical login roles.
```sql
create role hms_api_login_b login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls connection limit 20;
\password hms_api_login_b
grant hms_api to hms_api_login_b;
alter role hms_api_login_b set statement_timeout = '8s';
alter role hms_api_login_b set lock_timeout = '3s';
alter role hms_api_login_b set idle_in_transaction_session_timeout = '15s';
-- Render: switch Username to hms_api_login_b.gvgomzogbzbjhlcsimrx + new password, deploy, verify (step 5), then revoke the old one:
alter role hms_api_login nologin;
alter role hms_api_login password null;
select pg_terminate_backend(pid) from pg_stat_activity where usename = 'hms_api_login';
-- Next rotation: re-enable hms_api_login with a new password and retire _b.
```
Optional backstop: `alter role … valid until '<rotation date + 30 days>'` forces rotation. If someone forgets, the API goes down, so only do this together with a calendar alert.

#### 4. Network restrictions (Supabase) and Render egress
**How it works:**
- Supabase network restrictions are **project-wide**. They apply to *every* DB role (including `postgres`), on direct connections **and** the Supavisor pooler.
- They don't apply to the HTTPS APIs (PostgREST, Auth, Storage, supabase-js), the Dashboard or the Management API.
- They can't be scoped to `hms_api_login` alone; Supabase doesn't expose per-role `pg_hba`.
- The rule set is IPv4 CIDRs plus IPv6 CIDRs, and an update **replaces** the previous rules unless `--append` is used.

**IPv4/IPv6 and the pooler:**
- Render's outbound traffic is IPv4 only.
- The direct host `db.gvgomzogbzbjhlcsimrx.supabase.co` is IPv6 only unless the paid IPv4 add-on is bought.
- So the API **must use the Supavisor pooler** (`<pooler-host>`, IPv4): transaction mode `:6543` for the API, session mode `:5432` only for tools that need sessions.
- If direct IPv6 connections should keep working for admin use, add that admin's IPv6 prefix too. An empty IPv6 list blocks all IPv6.

**Render egress options:**

| Option | What you allow-list | Trade-off |
|---|---|---|
| Shared regional ranges (any plan, incl. Free) | The Singapore ranges shown under service → Connect → **Outbound** (visible only once a service exists; none does today) | Free. But those ranges are shared by **all Render customers in Singapore**, so they narrow the attack surface without isolating it. Ranges can change (Render moved its regions to new ranges in Nov 2025; Singapore switched on 2025-11-07), so subscribe to Render's changelog. |
| Dedicated outbound IPs | 3 static IPv4s per set, per region | Exclusive to the workspace. Needs a **Render Pro workspace** plus **$100/month per IP set**. This is a purchase. |
| Static-IP proxy (e.g. QuotaGuard) | The proxy's IPs | Extra hop, extra vendor and latency, and Postgres traffic needs a SOCKS/TCP tunnel sidecar. Not recommended. |

**Region note:** the DB is in `ap-south-1` (Mumbai) and Render's nearest region is Singapore, adding about 30–60 ms per round trip. Keep queries per request low (see Minor 2 in the review).

**Who else needs access once restrictions are on:**
- Mohith's admin IP (`/32`, plus an IPv6 `/128` or `/64` if he connects directly).
- CI doesn't need access today: all CI databases are local.
- A future `supabase db push` from GitHub Actions would be **blocked**, because runner IPs vary. Plan to apply migrations from an allow-listed machine, through the Supabase GitHub integration, or by temporarily adding the IP.
- Edge Functions lose direct DB access (none are used).

**Commands (read first, then apply).** The update **replaces** rules. Not run, and they need a Supabase access token that isn't on this box.
```bash
supabase network-restrictions get    --project-ref gvgomzogbzbjhlcsimrx --experimental
supabase network-restrictions update --project-ref gvgomzogbzbjhlcsimrx --experimental \
  --db-allow-cidr <render-singapore-range-1> --db-allow-cidr <render-singapore-range-2> \
  --db-allow-cidr <mohith-admin-ipv4>/32 [--db-allow-cidr <mohith-admin-ipv6>/64]
# Management API equivalent: POST https://api.supabase.com/v1/projects/gvgomzogbzbjhlcsimrx/network-restrictions/apply
#   {"dbAllowedCidrs":["<…>"],"dbAllowedCidrsV6":["<…>"]}
```
The response's `entitlement` field shows whether the Free plan allows this. Also enforce TLS: `supabase ssl-enforcement update --project-ref gvgomzogbzbjhlcsimrx --enable-db-ssl-enforcement --experimental`.

#### 5. CONNECTION LIMIT sizing
- Supavisor opens server connections **per user + database + mode**, up to the project's **Pool Size**. Supabase's published default for Micro is **15**; read the actual value in Dashboard → Database → Settings → Connection pooling.
- So `hms_api_login` in transaction mode uses at most `pool_size` server connections, no matter how many Render instances run. Old and new instances during a deploy share the same pool.
- `CONNECTION LIMIT 20` = 15 (transaction pool) + 5 headroom for a session-mode or admin probe.
- Rule: **CONNECTION LIMIT ≥ Supavisor pool size**. Otherwise Supavisor gets `too many connections for role "hms_api_login"` under load. If Pool Size is raised, raise the limit in the same change.
- Total budget on Nano/Micro: `max_connections = 60` must cover Supavisor pools (per user/mode) + direct connections + Supabase's own services (Auth, PostgREST, Storage, health checks; 12 backends were already in use when I checked). Keep app pools ≤ ~40–50 % of 60.
- Client side: Npgsql `Maximum Pool Size=10` per Render instance. Client connections count against Supavisor's 200-client cap on Nano/Micro, not against `max_connections`.
- Monitoring query: `select usename, state, count(*) from pg_stat_activity where usename like 'hms_api_login%' group by 1,2;`. `client_addr` shows Supavisor, not Render.

---

## Minor 9. CI on Supabase's real stack (prototype job)

> 9. **CI uses vanilla `postgres:17` plus a shim instead of Supabase's image.** `.github/workflows/ci.yml:61-88`. Hosted-only behaviour isn't exercised: grants on predefined roles, PG16+ `SET`/`ADMIN` options (the report notes the hosted `SET ROLE hms_api` probe was inconclusive), and the real `auth.uid()`/GoTrue hook invocation. Consider `supabase start` (or the `supabase/postgres` image) for the DB job.

### What was added (commit on `fix/pr1-devops`)

| File | Purpose |
|---|---|
| `.github/workflows/ci.yml` | New job **`db-supabase-prototype`**, check name `DB prototype on Supabase stack (supabase start, non-required)`. Appended at the end; the other four jobs are byte-for-byte unchanged. |
| `.github/supabase-ci/supabase/config.toml` | CI-only CLI config used with `--workdir`. Unneeded services off; `[auth.hook.custom_access_token]` → `pg-functions://postgres/identity/custom_access_token_hook`; `jwt_expiry = 900`, rotation on, reuse interval 10; only `public`/`graphql_public` exposed. |
| `.github/supabase-ci/.gitignore` | Ignores the migrations and seed copied in at run time, plus CLI state. |
| `.github/scripts/supabase-ci-sql-tests.sh` | Runs `supabase/tests/*.sql` against an **already migrated** database (no shim, no DB recreation). Reports every failing file. Refuses non-local hosts. |
| `.github/scripts/supabase-ci-hook-smoke.sh` | Real GoTrue: sign-up → membership → password sign-in must carry `tenant_id`/`hms_roles` from the hook; token lifetime; rotation; reuse rejection. Refuses non-local hosts. |

**Job flow:**
1. `actions/checkout@v7` → `supabase/setup-cli@v3` (CLI **2.119.0**: `supabase/postgres:17.11.0.002`, `supabase/gotrue:v2.197.0`) → psql client.
2. Copy `supabase/migrations` and `supabase/seed.sql` into the workdir. The DB team's files stay the source of truth, and nothing under `supabase/` is modified.
3. `supabase start -x realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor`. This runs GoTrue's own migrations, then applies **all repo migrations + seed as `postgres`** on the real image.
4. Smoke query: version, predefined roles (`rolsuper` etc.), GoTrue migration count, `supabase_migrations.schema_migrations`, seeded tenant and patient counts.
5. SQL tests **as `postgres`**, informational (`continue-on-error: true`). `postgres` is not a superuser on Supabase, just like hosted, so this step directly probes the PG16+ `SET`/`ADMIN` question (e.g. `07_api_role_test.sql`'s `set local role hms_api`).
6. SQL tests **as `supabase_admin`** (superuser, same privileges the existing `database` job has).
7. Hook / GoTrue smoke test through Kong (`/auth/v1`).
8. Container logs on failure; `supabase stop --no-backup` always.

**Why it isn't required:** it has never run on GitHub, so its stability (image pulls of ~1–2 GB, start time, CLI output-format changes) is unproven. It has job-level **`continue-on-error: true`** and `timeout-minutes: 25`. It must **not** be added to the Q3 required list until it has been green on several pushed runs. After that, decide whether it replaces or supplements the `database` job.

### Validation: what ran and what didn't

| Check | Result |
|---|---|
| `actionlint` 1.7.12 (with shellcheck integration) on `ci.yml` and `cleanup.yml` | **clean** |
| `shellcheck` 0.11.0 on both new scripts | **clean** |
| CLI 2.119.0 config parse (`supabase start --workdir .github/supabase-ci`) | config **accepted**; it then stops with "docker: command not found". A deliberately bad value (`jwt_expiry = "abc"`) gets `CliConfigParseError`, so the config really is parsed before Docker is needed. |
| Existing runner `supabase/scripts/run-sql-tests.sh` (vanilla + shim; what the `database` job runs) on a private throwaway PG 17.11 cluster | **103 assertions, 0 failures**, so nothing broke |
| New SQL runner on a DB whose `auth` schema was built by **real GoTrue v2.197.0 migrations** (75), then repo migrations + seed | **103 assertions, 0 failures**. The repo migrations, seed and tests work on GoTrue's real `auth.users`, `auth.uid()` and `auth.jwt()`. |
| Hook smoke test against a locally running **GoTrue v2.197.0** with the hook enabled | **13/13 checks passed** (claims, 900 s lifetime, rotation, reuse rejected). Plus the `info` line about family revocation; see Q5. |
| Host guards (both scripts refuse `db.example.com` and `gvgomzogbzbjhlcsimrx.supabase.co`) | exit 2 as intended |
| `supabase start` / the `supabase/postgres` image / Kong path | **[NOT VERIFIED]**: there's no Docker or Podman on the box. Not yet exercised: the "as postgres" parity run (a non-superuser `postgres`), the `supabase_admin` password convention (local default `postgres`), and the `supabase status -o env` variable names (the step prints the names it found, and falls back from `PUBLISHABLE_KEY` to `ANON_KEY`). |
| .NET and frontend tests | not re-run: no .NET SDK on the box, and this branch doesn't touch `apps/` or `backend/`. |

All local runs used a private PG cluster on `127.0.0.1:55432`, created and destroyed in `/tmp`, so the shared box Postgres (other teams' `hms_*` databases) was never touched.

### Next actions
1. CTO merges `fix/pr1-devops` with the other fix branches and pushes once (FIX-PLAN order). Then read the `db-supabase-prototype` log:
   - Did the `postgres` parity step pass? If `set local role hms_api` fails there, the DB team should decide whether `postgres` needs `grant hms_api to postgres with set true` on hosted, or whether that test should run as the login role only.
   - Does reuse detection revoke the token family on the real stack?
2. After 3–5 green runs, decide whether this job replaces the `database` job's shim path. Only then consider adding it to required checks. That would be another change needing Mohith's approval.

---

## Summary of approvals needed from Mohith

1. **GitHub plan:** upgrade `kakani-dev` to GitHub Pro (paid), or move the repo to an org on Team, so `main` can be protected. Then apply **Q3 Option A or B** to require the four CI checks, **including `database` and `e2e`**. Don't include the prototype or `vercel`.
2. **Supabase Auth (hosted):** read the current values (Q5 commands), then approve `jwt_exp=900`, `refresh_token_rotation_enabled=true`, `security_refresh_token_reuse_interval=10`. Optionally consider Supabase Pro for session timebox and inactivity timeout.
3. **`hms_api_login` on hosted (Q6 §2):** create the role with `CONNECTION LIMIT 20`, the timeouts, and the secret only in Render, using `\password`. Then adopt the 90-day rotation runbook (§3).
4. **Network restrictions (Q6 §4):** choose shared Render Singapore ranges (free, shared) or Render dedicated IPs (Pro workspace + $100/month), then apply the Supabase allow-list including his admin IP. Also enable SSL enforcement.
5. **Prototype CI job:** none now. It's non-required by design. Revisit after several green runs.
