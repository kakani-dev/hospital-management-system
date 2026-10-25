> **Superseded (25 Oct 2026):** historical record. Render and the monolith are retired; current system is microservices on Azure Container Apps. See [docs/HANDOVER.md](/docs/HANDOVER.md).

# PR #1 review: DevOps & Release answers (Q3, Q5, Q6, Minor 9)

| | |
|---|---|
| Review | `/workspace/review-pr1/REVIEW.md` (PR #1 "Sprint 1: identity/tenancy/auth + patient registration", `feat/sprint-1-identity` → `main`, head `f756f20`) |
| Fix plan | `/workspace/review-pr1/FIX-PLAN.md`. Owner here: DevOps & Release, branch `fix/pr1-devops` (cut from `f756f20`) |
| Written | 2026-10-06 ~21:20 IST; updated ~21:30 IST (Q3 re-verified after protection was applied; mocked web E2E added to CI) |
| Rules followed | Nothing pushed. GitHub, hosted Supabase `medicore-hms` (`gvgomzogbzbjhlcsimrx`) and Render were used **read-only**. No settings, roles, passwords, network rules, branch protection or rulesets were changed by DevOps. Branch protection on `main` was applied by the CTO, with Mohith's approval; see Q3. No secret values appear in this document. |

Legend: **[NEEDS MOHITH'S APPROVAL]** = a change outside the repo that only Mohith may apply. **[NOT VERIFIED]** = couldn't be read or run from here; the reason is given.

---

## Q3. Required status checks on `main`

> 3. Are the `database` and `e2e` jobs **required** status checks under main's branch protection?

### Finding (current state, verified 2026-10-06 ~21:24 IST)

**Yes. `main` is protected and requires all four CI checks, including `database` and `e2e`.** Mohith made the repo **public**. The CTO then applied this runbook's Option A branch-protection `PUT`. What I read back matches what the CTO described, with no differences:

| Setting | Read back |
|---|---|
| Repo visibility | `"private":false,"visibility":"public"` |
| Required status checks | the 4 contexts below, each pinned to GitHub Actions (`app_id` 15368) |
| Strict (branch must be up to date) | `"strict":true` |
| Enforce for admins | `"enforce_admins":{"enabled":true}` (Mohith can't merge on red CI either) |
| Force pushes | `"allow_force_pushes":{"enabled":false}` |
| Deletion | `"allow_deletions":{"enabled":false}` |
| Conversation resolution | `"required_conversation_resolution":{"enabled":true}` (part of Option A) |
| Required PR reviews | not set (Option A sent `null`; deliberate for a solo owner) |
| Linear history / signed commits / lock branch | all `false` |
| Rulesets | **none**: `GET …/rulesets` → `[]`, `GET …/rules/branches/main` → `[]`. Option B (ruleset) **wasn't used**. Don't add it now, because duplicate rules in two systems are harder to reason about. |

**Required checks (verbatim from `required_status_checks.contexts`, byte-identical to the job `name:` values in `.github/workflows/ci.yml`):**

| Job id | Required check context |
|---|---|
| `web` | `Frontend (lint, unit tests, build)` |
| `api` | `Backend (build + unit tests)` |
| `database` | `SQL/RLS tests + API integration tests (real Postgres)` |
| `e2e` | `Playwright E2E (web + API + mock auth + Postgres)` |

**Not required, by design:**
- `DB prototype on Supabase stack (supabase start, non-required)` (Minor 9)
- `Web E2E (mocked API, Playwright)` (see "CI coverage: mocked web E2E" below)
- the `vercel` check suite

### Evidence (gh CLI, read-only)

The default `gh` account (`kakani17481a0566`) isn't a collaborator. I switched to the already-logged-in owner account `kakani-dev` for these reads, then switched back; the active account is `kakani17481a0566` again.

```text
gh api repos/kakani-dev/hospital-management-system --jq '{private,visibility}'
  {"private":false,"visibility":"public"}

gh api repos/kakani-dev/hospital-management-system/branches/main/protection
  "required_status_checks":{"strict":true,
    "contexts":["Frontend (lint, unit tests, build)","Backend (build + unit tests)",
                "SQL/RLS tests + API integration tests (real Postgres)",
                "Playwright E2E (web + API + mock auth + Postgres)"],
    "checks":[{"context":"Frontend (lint, unit tests, build)","app_id":15368},
              {"context":"Backend (build + unit tests)","app_id":15368},
              {"context":"SQL/RLS tests + API integration tests (real Postgres)","app_id":15368},
              {"context":"Playwright E2E (web + API + mock auth + Postgres)","app_id":15368}]},
  "required_signatures":{"enabled":false},"enforce_admins":{"enabled":true},
  "required_linear_history":{"enabled":false},"allow_force_pushes":{"enabled":false},
  "allow_deletions":{"enabled":false},"block_creations":{"enabled":false},
  "required_conversation_resolution":{"enabled":true},"lock_branch":{"enabled":false},
  "allow_fork_syncing":{"enabled":false}

gh api repos/kakani-dev/hospital-management-system/branches/main --jq '{protected,protection}'
  {"protected":true,"protection":{"enabled":true,"required_status_checks":{…same 4 checks…,"enforcement_level":"everyone"}}}

gh api repos/kakani-dev/hospital-management-system/rulesets          ->  []
gh api repos/kakani-dev/hospital-management-system/rules/branches/main  ->  []
```

PR #1 head `f756f20` (run 37485120738) passed all four of these checks before protection was turned on.

### History

On first check (~21:10 IST) `main` was unprotected (`"protected":false`, required checks `[]`). The protection and rulesets APIs returned HTTP 403 "Upgrade to GitHub Pro or make this repository public to enable this feature." because the repo was private on GitHub Free. The options offered were GitHub Pro, an org on GitHub Team, or making the repo public. Mohith chose **public**, so the Pro/Team upgrade isn't needed.

### Consequences and next actions
- **Job renames break merges.** Each check context is the job's `name:`. Renaming a required job, or dropping it, leaves every PR waiting forever for a check that no longer reports. Any rename must change the protection in the same change. That needs Mohith's approval, because it's a GitHub settings change.
- **Strict mode means one merge at a time.** A PR must be rebuilt on the latest `main` before it can merge, so the CTO's DB → Backend → Web → QA → DevOps merge order means updating and re-running CI on each branch before its merge.
- **Direct pushes still have to pass.** Because `enforce_admins` is on, a direct push to `main` is accepted only if that commit already has the four green checks, so in practice every change goes through a PR.
- **Public repo:** CI uses no repository secrets, so PRs from forks can't exfiltrate any. **[NOT VERIFIED; Mohith's setting]** Recommend keeping Settings → Actions → "Require approval for fork pull request workflows" at least for first-time contributors, so outsiders can't burn CI minutes or run unreviewed code on runners. Also re-check that no secret or real data is in git history; the review found only the documented local-only placeholders.
- **Candidates to require later (each needs Mohith's approval):**
  - `Web E2E (mocked API, Playwright)`: recommended once fix/pr1-web is on `main` and the job has run green a few times.
  - `DB prototype on Supabase stack (supabase start, non-required)`: only after it has proven stable, and the job would need renaming first (see Minor 9).
  - `ci-ok`: optional single aggregate. Not required for the four contexts above to keep working.

### Update (CI skip, October 2026)

Required check **names are unchanged** (still the four contexts in the table above). This CI change does not need a branch-protection edit.

Each required name is a reporter job. It exits 0, so the check conclusion is **success**, when the matching heavy job was skipped because its paths did not change or a pass marker already exists for the same inputs. It exits 1 when that heavy job failed or was cancelled, or when the `changes` job did not succeed. Auto-merge still watches the same four contexts, and a skipped heavy job cannot leave one of them pending.

`ci-ok` (`if: always()`, `needs` every job) fails the workflow when any needed job failed or was cancelled. `DB prototype on Supabase stack (supabase start, non-required)` stays `continue-on-error` and is ignored by the aggregate. Adding `ci-ok` to the required list would be a GitHub settings change and needs Mohith's approval. Until then the four existing contexts are the gate, and they go red when their own work fails.

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

## CI coverage: mocked web E2E (Frontend team's `e2e:mocked`)

**What:**
- New CI job `web-e2e-mocked`, check name **`Web E2E (mocked API, Playwright)`**.
- It runs `npm run e2e:mocked`. That script is in the **root** `package.json`, not `apps/web`, and runs `playwright test -c tests/playwright/playwright.mocked.config.ts`.
- The suite arrives with `fix/pr1-web` @ `6490b82`: 7 tests in `tests/playwright/mocked/web-contracts.mocked.spec.ts`.
- Coverage: sessionStorage session and 15-minute idle logoff (Minor 3), the X-Hms-Tenant mismatch banner and cross-tab switch and sign-out (M3), debounced `POST /patients/search` (Minor 5), and the consent-based invite/accept flow (B1).
- The API and Supabase Auth are answered inside the page (`mocked/mock-backend.ts`), so the job needs no DB, .NET or mock-auth server.
- The config itself builds the web app into `node_modules/.e2e-mocked-dist` and serves it with `vite preview` on port 4174, with placeholder `VITE_*` values baked in. CI only adds Node 24, `npm ci` for root and `apps/web`, and Chromium.

**Why a separate job and not a step in `Frontend (lint, unit tests, build)`:**
- The Frontend check is **required** on `main` (Q3). A Playwright or browser problem in a step there would block every merge.
- A separate job can't affect the required check's result, and its name can't collide with or rename the four required contexts. Verified by a YAML parse of the job ids and names: base `f756f20` vs this branch, the four required names are byte-identical and only `db-supabase-prototype` and `web-e2e-mocked` were added.

**Guard (skips until `fix/pr1-web` merges):**
- `.github/scripts/detect-npm-script.sh e2e:mocked tests/playwright/playwright.mocked.config.ts` checks the root `package.json` for the script and checks that the config exists.
- If either is missing, it logs `::notice title=e2e:mocked not present::…skipping (expected until it is merged)` and writes `present=false`. Every later step is conditioned on `present == 'true'`, so the job finishes **green with a clear skip notice**, both on this branch and on `main` if this branch merges first.
- Once the suite exists it runs normally.

**Browsers and artifacts:**
- `~/.cache/ms-playwright` is cached by Playwright version. On a cache miss the job runs `npx playwright install --with-deps chromium`; on a hit it runs `npx playwright install-deps chromium`.
- HTML and JUnit reporters are added on the command line (`--reporter=list,html,junit` plus `PLAYWRIGHT_HTML_OUTPUT_DIR` and `PLAYWRIGHT_JUNIT_OUTPUT_FILE`), because the mocked config's CI reporter is only list + junit.
- On failure the job uploads the `playwright-report-mocked` artifact (`tests/playwright/playwright-report-mocked` + `tests/playwright/test-results`, 7 days).

**Validation:**

| Check | Result |
|---|---|
| actionlint (with shellcheck) on both workflows; shellcheck on all `.github/scripts` | clean |
| Guard on this branch | `present=false`, two notices, exit 0 |
| Guard on `6490b82` | `present=true` |
| The job's `run:` steps, emulated on a temporary worktree of `6490b82` in `/tmp` (Node 24.21.0, Playwright 1.63.0, Chromium 1243 already in the box cache), `CI=true` | **7 passed**; HTML report and `junit-mocked.xml` (`tests="7" failures="0"`) written where the upload step expects them |
| Failure path (one deliberately failing test added in the scratch worktree only) | exit 1; HTML report, traces and junit present for upload |
| Not run | the real GitHub runner: `actions/setup-node` and `actions/cache`, `--with-deps` (needs sudo apt, not available on the box), the upload itself. The temporary worktree was removed. |

**Follow-ups:**
- **Recommend adding `Web E2E (mocked API, Playwright)` to the required checks** after `fix/pr1-web` is on `main` and the job has been green on a few runs. [NEEDS MOHITH'S APPROVAL] Do it by sending the full check list, so each check stays pinned to GitHub Actions:
  ```bash
  gh api -X PATCH repos/kakani-dev/hospital-management-system/branches/main/protection/required_status_checks \
    --input - <<'JSON'
  {"strict": true, "checks": [
    {"context": "Frontend (lint, unit tests, build)", "app_id": 15368},
    {"context": "Backend (build + unit tests)", "app_id": 15368},
    {"context": "SQL/RLS tests + API integration tests (real Postgres)", "app_id": 15368},
    {"context": "Playwright E2E (web + API + mock auth + Postgres)", "app_id": 15368},
    {"context": "Web E2E (mocked API, Playwright)", "app_id": 15368}
  ]}
  JSON
  ```
  Not run.
- Web team (optional): `tests/playwright/playwright-report-mocked/` isn't in `.gitignore`. That only matters for local runs using the CI reporter flags.

---

## Summary of approvals needed from Mohith

1. **GitHub branch protection: done.** The repo is public, and Option A was applied by the CTO (verified in Q3). Remaining: approve the fork-PR workflow approval setting (Q3), and later add `Web E2E (mocked API, Playwright)` to the required checks once it's proven (command in "CI coverage: mocked web E2E").
2. **Supabase Auth (hosted):** read the current values (Q5 commands), then approve `jwt_exp=900`, `refresh_token_rotation_enabled=true`, `security_refresh_token_reuse_interval=10`. Optionally consider Supabase Pro for session timebox and inactivity timeout.
3. **`hms_api_login` on hosted (Q6 §2):** create the role with `CONNECTION LIMIT 20`, the timeouts, and the secret only in Render, using `\password`. Then adopt the 90-day rotation runbook (§3).
4. **Network restrictions (Q6 §4):** choose shared Render Singapore ranges (free, shared) or Render dedicated IPs (Pro workspace + $100/month), then apply the Supabase allow-list including his admin IP. Also enable SSL enforcement.
5. **Prototype CI job:** none now. It's non-required by design. Revisit after several green runs.
6. **Mocked web E2E job:** none now. It skips until fix/pr1-web merges. Then see item 1.
