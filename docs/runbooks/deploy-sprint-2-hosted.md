# Runbook: Sprint 2 hosted DB update + API/web redeploy (after PR #2 merges)

> **Status: PREPARED ONLY. Nothing in §1–§7 runs until the CTO gives an explicit GO (relaying Mohith's
> approval) for this exact plan (§8).** Prepared 2026-10-09 ~18:30 IST against PR #2 head `77b34f2`.
> Hosted project: `medicore-hms` / `gvgomzogbzbjhlcsimrx` (Free plan, PG 17.11, ap-south-1).
> Secrets appear only as `$(cat /home/box/.secrets/...)`; never echo them, never `set -x`.

Scope (in this order): `20261009090000` (N1, already on main) → Sprint 2 `20261010090000` … `20261010090400`
→ Azure API redeploy from main → Vercel web from main → Sprint 2 smoke.

Files used (all in this branch, under `supabase/scripts/hosted/`, all READ-ONLY except the generated apply SQL):

| file | purpose |
|---|---|
| `sprint2-precheck.sql` | read-only pre-state check (§2) |
| `backup-export.sql` | read-only JSON export of every app row (§1) |
| `catalog-fingerprint.sql` | read-only catalog fingerprint (§1, §5) |
| `build-guarded-apply.py` | generates the single-transaction guarded apply SQL (§3, §4) |
| `sprint2-verify.sql` | read-only post-apply checks, every `*_ok` must be `t` (§5) |
| `scripts/smoke/deploy-smoke-sprint2.sh` | Sprint 1 + Sprint 2 smoke (§7) |

---

## 0. Current hosted state (verified read-only, 2026-10-09 ~18:10 IST)

`select version, name, md5(array_to_string(statements, E'\n')) from supabase_migrations.schema_migrations order by version;`

| version | name | md5(recorded) == md5(repo file) |
|---|---|---|
| 20261006090000 | foundation_schemas | 2419b6ba… ✅ |
| 20261006090100 | identity_tenancy | de581f81… ✅ |
| 20261006090200 | identity_rls_helpers | 454d7156… ✅ |
| 20261006090300 | patient_registry | 404f3b8d… ✅ |
| 20261006090400 | audit_log | 96539d0d… ✅ |
| 20261006090500 | rls_policies_and_grants | 82088b6b… ✅ |
| 20261006090600 | advisor_fixes | 68977c5a… ✅ |
| 20261007090000 | auth_context_and_api_role | 30965351… ✅ |
| 20261008090000 | membership_invite_consent | 41748ec9… ✅ |

- **History repair: NOT needed.** The Oct 6 repair (~21:38 IST) renamed the 8 apply-time versions to the repo
  versions; all 9 rows now carry the repo version and the byte-identical repo text.
- **20261008090000: applied** (row present, text identical to the repo file).
- **20261009090000: NOT applied** — no history row, `identity.memberships.status` default is still `'active'`,
  and `hms_api` still has EXECUTE on `identity.accept_membership(uuid)` (both change in N1).
- Sprint 2: nothing present (no `appointment` / `messaging` schema, no `hms_dispatcher`, `btree_gist` available 1.7
  but not installed, `patient.patients` has no `deleted_by` / `deletion_reason`).
- Data: 2 tenants, 3 branches (all `Asia/Kolkata`), 7 memberships, 7 user_profiles, 9 patients (0 soft-deleted), 21 audit rows.
- Roles: `hms_api` (NOLOGIN NOINHERIT), `hms_api_login` (LOGIN NOINHERIT, CONNECTION LIMIT 20, member of `hms_api` with SET).
- Advisors baseline: security = 1 WARN (`auth_leaked_password_protection`, Auth setting, unrelated);
  performance = 2 INFO (unused indexes `audit_log_tenant_time_idx`, `user_profiles_active_context_idx`).
- Data API exposure (Q1): only `public, graphql_public` are exposed. Keep `appointment` and `messaging` OUT of
  the exposed schemas (Dashboard → Settings → API); the app only reaches them through the .NET API.

## 1. Backup / snapshot (choose one; recommendation: **C**)

Free plan: no PITR. The box has **no DB password and no Supabase CLI login**, and box egress to the pooler
(`aws-0-ap-south-1.pooler.supabase.com:6543`) times out (tested 2026-10-09), so nothing can `pg_dump` from here.

- **A. `pg_dump` with the `hms_api_login` connstr — NOT viable.** Verified read-only: `hms_api_login` and `hms_api`
  have no USAGE on `patient`/`identity`/`audit` and no SELECT on any table (fail-closed by design); via
  `SET ROLE authenticated` without JWT claims RLS returns 0 rows. A dump would be empty/permission-denied — and
  the pooler is unreachable from the box anyway. Do **not** grant it read rights for this.
- **B. Supabase Dashboard backup** (Dashboard → Database → Backups). Free projects get no PITR; scheduled daily
  backups, if listed, are not a self-service restore you can rely on (and a restore would roll back the whole
  project, Auth included). Note what is listed, but don't make it the only safety net.
- **C. (Recommended) Read-only logical export + catalog fingerprint via Supabase MCP `execute_sql`** (runs as
  `postgres`; synthetic data, tens of rows):
  ```bash
  TS=$(TZ=Asia/Kolkata date +%Y%m%d-%H%M); B=/workspace/deploy-evidence/backup-sprint2-$TS; mkdir -p $B
  # 1) MCP execute_sql(project_id=gvgomzogbzbjhlcsimrx, query=<contents of supabase/scripts/hosted/backup-export.sql>)
  #    -> save the JSON result verbatim to $B/data.json
  # 2) MCP execute_sql(query=<contents of supabase/scripts/hosted/catalog-fingerprint.sql>) -> $B/fingerprint-before.json
  # 3) MCP list_migrations -> $B/history-before.json
  python3 -c "import json;d=json.load(open('$B/data.json'));print({k:len(v) for k,v in d.items() if isinstance(v,list)})"
  # expect: tenants 2, branches 3, user_profiles 7, memberships 7, patients >= 9, audit_log >= 21
  ```
  Restore path (only if data were damaged, which none of these migrations does): re-insert rows from `data.json`
  as `postgres` (`insert … select * from jsonb_populate_recordset(null::<table>, '<json>')`), parents first.
  Every migration in scope is additive or replaces functions/policies; none rewrites or deletes rows.

## 2. Migration state check (read-only; must match before anything is applied)

Run `supabase/scripts/hosted/sprint2-precheck.sql` via MCP `execute_sql`. Expected:

| column | expected |
|---|---|
| `pg_version` | `17.x` |
| `history` | exactly the 9 versions in §0 |
| `pending_rows_present` | `0` |
| `membership_status_default` | `'active'::text` |
| `hms_api_exec_accept` | `true` |
| `sprint2_schemas_present`, `hms_dispatcher_present`, `patient_new_cols` | `0` |
| `btree_gist_installed` / `btree_gist_available` | `null` / non-null |
| `api_roles` / `api_login_connlimit` | `2` / `20` |
| `row_counts` | matches §1 export |

**Any mismatch → STOP and report.** (The generated apply SQL also refuses to run unless the history matches.)

## 3. PR #1 chain

1. **History repair — not needed** (§0). Do not run `supabase migration repair`.
2. **20261008090000 — already applied; verify only:** history row present with md5 `41748ec97b2a766b1c53cc3a12dbee0f`
   (= repo file) and `select tgname from pg_trigger where tgname = 'memberships_consent';` returns 1 row.
3. **20261009090000_membership_invite_per_branch (N1/N4/N6)** — needs its own approval (it was never part of the
   Oct 6 approval). What it does: `identity.add_member()` dedupes on (tenant, user, branch) and inserts NEW
   `invited` rows (per-branch invites); `memberships.status` default `'active'` → `'invited'` (existing rows
   untouched); revokes the no-op EXECUTE grants of `accept_membership()` / `my_invitations()` from `hms_api`.
   Pre-checks: §2 all green. Compatibility: the live API (main) calls these functions as `authenticated`
   (RlsTransactionInterceptor), so the revoke does not affect it.

### How to apply (both §3.3 and §4)
**Do not use the MCP `apply_migration` tool**: it records the migration under a NEW timestamp version (this is how
the history drifted on Oct 6). Use the same method as the Oct 6 write: one guarded transaction via MCP
`execute_sql`, generated from the merged main checkout:
```bash
cd <checkout of main after PR #2 merge>/supabase
git log -1 --format=%H    # record it
sha256sum migrations/20261009090000_*.sql migrations/2026101009*.sql   # must equal the manifest below
B=20261006090000,20261006090100,20261006090200,20261006090300,20261006090400,20261006090500,20261006090600,20261007090000,20261008090000
python3 scripts/hosted/build-guarded-apply.py --expect-before $B \
  migrations/20261009090000_membership_invite_per_branch.sql > /tmp/apply-n1.sql
python3 scripts/hosted/build-guarded-apply.py --expect-before $B,20261009090000 \
  migrations/20261010090000_*.sql migrations/20261010090100_*.sql migrations/20261010090200_*.sql \
  migrations/20261010090300_*.sql migrations/20261010090400_*.sql > /tmp/apply-s2.sql
# then: MCP execute_sql(query=<contents of /tmp/apply-n1.sql>), verify (§5 n1_* columns),
#       MCP execute_sql(query=<contents of /tmp/apply-s2.sql>), verify (§5 all columns)
```
Each generated script: `BEGIN` → `lock_timeout 10s`, `statement_timeout 120s` → **history guard** (aborts unless
history is exactly the expected pre-state) → the repo file text verbatim → `INSERT` into
`supabase_migrations.schema_migrations (version, name, statements)` exactly like `supabase db push` → **text guard**
(md5 of the recorded statement must equal the repo file's md5) → **post guard** (history = pre + applied) → `COMMIT`.
Any error rolls everything in that script back. The Sprint 2 script applies all five files atomically.

Expected manifest (PR #2 head `77b34f2`; if PR #2 changes before merge, re-run the dry run and update this table):

| file | sha256 | md5 |
|---|---|---|
| 20261009090000_membership_invite_per_branch.sql | `fab87fc7ae1c93889a959dc5c0af5f2950a27503a1e534b159b1d5fb16342aaa` | `b41fa95502baef644e18da6874e4383f` |
| 20261010090000_patient_soft_delete_and_duplicates.sql | `8a86eb31284e5acdfbbd79731df17b97cae7a076e3511982fce2cf9adced0c29` | `8412fb02b6c637004ca284661f598a60` |
| 20261010090100_appointment_schema.sql | `e68723268943b3ae7b47554c93af47c96fac4bb6e91e8a25f9aebb1e5f0f1baa` | `18f2489e0c133743b1717afba5c4c468` |
| 20261010090200_opd_queue.sql | `9343a1f99fe5c0d552eaf4233fd6bd4294565a186d6d18a66c6274883dcbd34a` | `512c5261ef88c440b4b0533c2b987816` |
| 20261010090300_outbox.sql | `79aff7d50e95b91adeb58801dece699763534dd73a43b929c2e7dd5d97fc92fb` | `bb5d69ecd1442182f5b0d91445c6f25b` |
| 20261010090400_pr2_review_fixes.sql | `e6174ba0897969daf076ca715ee49d72685f69f3c6ee6fe1e8ee3353c65624cf` | `a892422a684cf0f0a14d3f7e4896f846` |

Alternative if a Supabase CLI login + DB password become available: `supabase link --project-ref gvgomzogbzbjhlcsimrx`,
`supabase db push --dry-run` (must list exactly the 6 files above, nothing else), then `supabase db push`.

## 4. Sprint 2 migrations (apply in this order, after §3.3)

| # | migration | summary | risk flags |
|---|---|---|---|
| 1 | `20261010090000_patient_soft_delete_and_duplicates` | `deleted_by`/`deletion_reason` columns + 2 CHECKs; soft delete/restore only via `patient.soft_delete_patient()` / `restore_patient()` (SECURITY DEFINER); `find_duplicate_patients()` (INVOKER); `normalize_phone()`; 3 partial indexes | **RLS change**: deleted rows visible to tenant_admin only (0 deleted today); **grant revoke**: `UPDATE(deleted_at)` from `authenticated`; CHECKs validate existing rows (safe: 0 deleted); `CREATE INDEX` (non-concurrent, 9 rows, ms) |
| 2 | `20261010090100_appointment_schema` | `CREATE EXTENSION btree_gist` (schema `extensions`); new schema `appointment`: practitioners, schedules (no-overlap EXCLUDE), appointments (status machine trigger, no-double-booking EXCLUDE); `available_slots()` (DEFINER, no PHI); RLS + column grants for `authenticated` | new extension; new SECURITY DEFINER functions; new RLS policies; no data touched |
| 3 | `20261010090200_opd_queue` | `queue_counters` (RPC-only, RLS no policies), `queue_entries`; `check_in()`, `check_in_walk_in()`, `set_queue_status()` (DEFINER), internal `issue_queue_token()` (no client EXECUTE) | new DEFINER RPCs (the API calls them as `authenticated`); no client DML on queue tables |
| 4 | `20261010090300_outbox` | schema `messaging`, `outbox` table (RLS, no client grants); AFTER triggers enqueue appointment/queue events (no PHI); **new role `hms_dispatcher` (NOLOGIN NOINHERIT)** + `GRANT hms_dispatcher TO hms_api`; claim/complete/fail RPCs for it | **new role + role grant** (needs CREATEROLE: hosted `postgres` has it; as creator it gets ADMIN, so the GRANT works). Dispatcher is OFF by default (`Outbox:Dispatcher:Enabled=false`) — events accumulate as `pending`, harmless |
| 5 | `20261010090400_pr2_review_fixes` | MAJ-1: AFTER UPDATE trigger cancels the active queue entry when an appointment is cancelled / no-show; MIN-3: `patients_update_registry_writers` USING also requires access to the patient's current branch | **RLS tightening** (branch-scoped writers can no longer edit other branches' patients; tenant admins unaffected) |

No destructive DDL (no DROP TABLE/COLUMN, no type changes), no data backfills, no new grants to `hms_api` beyond
membership in `hms_dispatcher`, nothing `hms_api_login` needs beyond what it has (`SET ROLE authenticated`;
`SET ROLE hms_dispatcher` only if the dispatcher is enabled later). Locks: brief ACCESS EXCLUSIVE on
`patient.patients` (ALTER TABLE + policy swap) and on `identity.memberships` (N1 default change); tiny tables,
`lock_timeout 10s` bounds the wait. The live main API stays compatible with the new schema during the window
(additive; it never writes `deleted_at`) — analysis, not runtime-tested against hosted.

Per-migration verification = the matching columns of §5. Rollback notes per migration: §6.

## 5. Verification after apply (read-only)

1. MCP `list_migrations` → 15 rows, last six = `20261009090000`, `20261010090000` … `20261010090400`.
2. MCP `execute_sql` with `supabase/scripts/hosted/sprint2-verify.sql` → **every `*_ok` column = `t`**
   (history, N1 default + revokes, patient columns / RPC-only `deleted_at` / functions, appointment + messaging
   tables, RLS enabled, `btree_gist`, EXCLUDE constraints, RPC grants, no client EXECUTE on internal functions,
   no client DML on queue/outbox, `hms_dispatcher` NOLOGIN + grant + EXECUTE, `hms_api_login` can
   `SET ROLE authenticated/hms_dispatcher` but does not inherit, MAJ-1 trigger, MIN-3 policy) and
   `patients_now` / `memberships_now` unchanged vs §1.
3. Catalog fingerprint after (`catalog-fingerprint.sql`) → `$B/fingerprint-after.json`; diff vs before: only
   additions in `appointment`/`messaging`/`patient` + the N1/090000/090400 function and policy changes.
4. MCP `get_advisors` security + performance: no new ERROR/WARN beyond the §0 baseline (new unused-index INFOs on
   empty tables are expected).
5. Data API: `appointment`/`messaging` still NOT in exposed schemas.

## 6. Rollback

Default is **forward-fix** (a new migration), because every step is additive and a down-migration loses the new data.
If the apply script fails, its transaction rolls back by itself — nothing to undo; report the error.

Manual reverts (only with a separate approval, API first rolled back to the pre-merge build, then delete the matching
`schema_migrations` rows so history stays truthful):

| migration | revert |
|---|---|
| 20261010090400 | `drop trigger appointments_cancel_queue_entry on appointment.appointments; drop function appointment.cancel_queue_entry_for_appointment();` recreate the 090000 `patients_update_registry_writers` policy |
| 20261010090300 | `drop trigger appointments_outbox …; drop trigger queue_entries_outbox …; drop function appointment.emit_*_event(); drop schema messaging cascade; revoke hms_dispatcher from hms_api; drop role hms_dispatcher;` (loses outbox events) |
| 20261010090200 | `drop function appointment.check_in*/set_queue_status/issue_queue_token; drop table appointment.queue_entries, appointment.queue_counters;` (loses queue data) |
| 20261010090100 | `drop schema appointment cascade;` (loses practitioners/schedules/appointments); keep `btree_gist` |
| 20261010090000 | drop the 4 functions + 3 indexes + 2 CHECKs + 2 columns; recreate the 20261006090500 select/update policies; `grant update (deleted_at) on patient.patients to authenticated;` |
| 20261009090000 | re-run the `add_member` body from 20261008090000, `alter … status set default 'active'`, re-grant EXECUTE on `accept_membership`/`my_invitations` to `hms_api` |

App rollback: API → redeploy the previous zip (`/tmp/hms-api.zip` = main@3a81224, same backend as d1d848f; or rebuild d1d848f with the §7.1
commands); web → Vercel "Promote to Production" of `dpl_CmDeHEAHcu6TAb2ihKWMfSxGdS9D` (main@d1d848f). The old API
and web work against the migrated schema (additive).

## 7. After the DB: API → web → smoke

1. **Azure API** (same as `docs/runbooks/deploy-azure.md` on main; settings unchanged — connection string already
   carries `No Reset On Close=true`; `Outbox__Dispatcher__Enabled` stays unset = off on F1):
   ```bash
   export PATH=$HOME/.dotnet:$HOME/.local/bin:$PATH
   git -C /workspace/hms-wt/devops fetch origin && git -C /workspace/hms-wt/devops worktree add /tmp/hms-main-s2 origin/main
   cd /tmp/hms-main-s2/backend && rm -rf /tmp/hms-publish /tmp/hms-api-s2.zip
   dotnet publish gateway/Hms.Gateway/Hms.Gateway.csproj -c Release -o /tmp/hms-publish /p:UseAppHost=false
   python3 -c "import shutil; shutil.make_archive('/tmp/hms-api-s2','zip','/tmp/hms-publish')"
   az webapp deploy -g rg-medicore-hms-dev -n medicore-hms-api --src-path /tmp/hms-api-s2.zip --type zip --async false -o none
   for i in $(seq 10); do curl -s -o /dev/null -w "%{http_code} " https://medicore-hms-api.azurewebsites.net/health/ready; done   # all 200
   ```
   Only if the connection string ever has to be re-set:
   `az webapp config appsettings set -g rg-medicore-hms-dev -n medicore-hms-api -o none --settings ConnectionStrings__HmsDatabase="$(cat /home/box/.secrets/medicore-hms-connstr)" >/dev/null 2>&1`
2. **Web (Vercel)**: the merge to main auto-deploys production (observed for PR #3: `dpl_CmDeHEAH…`, git-triggered).
   Confirm via Vercel MCP `list_deployments` (project `prj_E7caJwNRXk3TMXBo4xnkcXmCI3hd`, target production,
   `githubCommitSha` = merge SHA, READY). If none appears within ~5 min: MCP `create_deployment` with
   `gitSource {type: github, org: kakani-dev, repo: hospital-management-system, ref: main, sha: <merge sha>}`,
   `target: production`. `VITE_API_BASE_URL` stays `https://medicore-hms-api.azurewebsites.net`.
   **Order matters**: DB → API → web, so the web never calls Sprint 2 endpoints the live API doesn't have.
3. **Smoke** (writes SMOKE-labelled rows: 1 patient, ≤1 practitioner "SMOKE Practitioner", ≤1 schedule for today's
   weekday 00:00–23:45, 1 appointment, 2 queue entries):
   ```bash
   cd /tmp/hms-main-s2   # or this branch until it merges
   WEB_URL=https://medicore-hms-three.vercel.app API_URL=https://medicore-hms-api.azurewebsites.net \
   PUBLISHABLE_KEY=sb_publishable_wKjEaH53IaWHuXif466l-A_WNlxxNTd \
     scripts/smoke/deploy-smoke-sprint2.sh | tee /workspace/deploy-evidence/smoke-sprint2.txt
   ```
   Steps: bundle → Azure + deep link `/appointments` 200; health live/ready; demo admin sign-in (password read from
   `/home/box/.secrets/medicore-demo-admin`, never printed); `GET /api/v1/me`; register + search patient;
   `GET/POST /api/v1/practitioners`; `GET/POST /api/v1/schedules`; `GET /api/v1/slots?branchId&from&to&practitionerId`;
   `POST /api/v1/appointments` (status `booked`); `POST /api/v1/appointments/{id}/check-in` (201, token);
   `GET /api/v1/queue?branchId&date` (entry `waiting`); `PATCH /api/v1/queue/{id}` `in_consultation` → `done`, then
   `GET /api/v1/appointments/{id}` = `completed`; `POST /api/v1/queue/walk-in` (201) then `PATCH … cancelled`.
   After ~23:45 branch time there are no free slots today: steps 10–13 are skipped (walk-in still runs) — run it
   earlier in the day for full coverage. Optional read-only follow-up: `select event_type, count(*) from messaging.outbox group by 1;`
   (expect `appointment.booked/checked_in/in_consultation/completed`, `queue.token_issued/status_changed`, all `pending`).

## 8. Go / no-go checklist (executes ONLY after the CTO's explicit GO)

- [ ] CTO GO received, naming: N1 `20261009090000` **and** Sprint 2 `20261010090000…090400`, the Azure redeploy, and the smoke writes
- [ ] PR #2 merged; merge SHA recorded; required CI green on main
- [ ] Migration files on main byte-identical to the §3 manifest (else re-run the local dry run first)
- [ ] §1 backup C saved (`data.json`, `fingerprint-before.json`, `history-before.json`) and counts sane
- [ ] §2 pre-check matches exactly
- [ ] No other hosted change in flight (Auth settings, roles); nobody else applying migrations
- [ ] Apply N1 → verify `n1_*` → apply Sprint 2 → full §5 verify all `t`
- [ ] API redeployed, `/health/ready` 10/10; web production on the merge SHA
- [ ] Smoke PASS saved to `/workspace/deploy-evidence/smoke-sprint2.txt` (no tokens/passwords)
- **NO-GO** on: any pre-check mismatch, any guard error, any `*_ok = f`, ready not stable, smoke failure that is
  not a known data/time-of-day skip → stop, report, forward-fix plan.

## 9. PR #4: audit columns, soft delete, tenant time zone (after §4; separate GO)

Order: N1 (§3) → Sprint 2 (§4) → `20261012090000_audit_columns_and_soft_delete` → `20261012090100_tenant_time_zone`
→ `20261012090200_enforce_appointment_transition_v1` → API deploy (§7.1, from the merged main). Apply the three files in one
`execute_sql` each, in that order, in a quiet window (no clinic hours: no check-ins, nobody editing branches).

- **Locks.** Each file starts with `set local lock_timeout = '5s'; set local statement_timeout = '120s';`. 090000 adds
  columns + triggers on every identity/patient/appointment table (brief ACCESS EXCLUSIVE each); 090100 alters
  `identity.tenants`/`identity.branches`. A `55P03 lock_not_available` (or `57014` statement timeout) aborts that file's
  transaction with nothing applied: wait a minute and retry the same file; after 3 failures stop and look for the blocker
  (`select pid, state, query_start, left(query, 80) from pg_stat_activity where datname = current_database() and state <> 'idle';`).
  Never raise the timeouts to force it through.
- **Compatibility.** The pre-PR-4 API keeps working on the new schema (`branches.timezone` stays NOT NULL and mirrors
  the effective zone; `created_at`/`updated_at` stay, derived). Proven locally: main's integration suite against main's
  schema + these three files passes except the schedules hard-delete test (DELETE is revoked by design; schedules are
  soft-deleted via `appointment.soft_delete_schedule`). So deploy the API right after the DB, not days later.
- **Data.** Existing `Asia/Calcutta` values are canonicalised to `Asia/Kolkata`; a branch zone equal to its tenant's zone
  becomes "inherit" (`timezone_override` null), any other becomes the override. No rows are deleted.
- **Verification (read-only):**
  ```sql
  select
    (select count(*) from identity.branches where timezone is null) = 0                                   as mirror_not_null_ok,
    (select count(*) from identity.branches b join identity.tenants t on t.id = b.tenant_id
      where b.timezone <> coalesce(b.timezone_override, t.time_zone)) = 0                                  as mirror_matches_ok,
    (select count(*) from identity.branches where timezone like 'Asia/Calcutta' or timezone_override like 'Asia/Calcutta')
      + (select count(*) from identity.tenants where time_zone = 'Asia/Calcutta') = 0                     as calcutta_ok,
    not exists (select 1 from pg_proc where proname like '%\_v1' and pronamespace::regnamespace::text in
      ('identity','patient','appointment') and has_function_privilege('authenticated', oid, 'execute')
      and proname not in ('branch_time_zone_v1','branch_local_date_v1',
                          'assert_zone_change_allowed_v1','change_time_zone_v1'))                as v1_grants_ok,
    (select count(*) from pg_proc where prosrc like '%hms.soft_delete%') = 0                               as no_soft_delete_flag_ok;
  ```
  All columns `t`, then MCP `get_advisors` (no new ERROR/WARN) and the §7 smoke, plus `PATCH /api/v1/tenants/current`
  with the current zone (200, no change).
- **Rollback.** Forward-fix only (the expand step is additive, and reverting would lose `*_on`/`*_by` stamps and soft-delete
  state). The contract step (dropping the legacy columns) is tracked in `docs/runbooks/audit-columns-contract.md`.

## Appendix: local dry run (2026-10-09, PG 17.11 throwaway cluster in /tmp, removed afterwards)

- **Stage A (hosted order)**: shim → migrations 1–9 → main `seed.sql` (7 patients) → `20261009090000` → Sprint 2 five:
  all applied cleanly (25–103 ms each); `sprint2-verify.sql` all `t`, data counts unchanged.
- **Stage B (full repo chain + tests)**: `supabase/scripts/run-sql-tests.sh` on the throwaway server: 15 migrations +
  PR #2 seed, **409 assertions, 0 failures** (tests 01–15).
- **Stage C (exact hosted procedure)**: history table seeded with the 9 hosted rows (md5s identical to hosted) →
  `apply-s2.sql` before N1 **aborted by the history guard** (nothing applied) → `apply-n1.sql` OK → re-run of
  `apply-n1.sql` aborted by the guard → `apply-s2.sql` OK (117 ms) → `sprint2-verify.sql` all `t`.
- CI on PR #2 (supabase/postgres stack): migrations apply, 409/409 as `supabase_admin`. As non-superuser `postgres`
  the test files 06/07/08/13 fail at `SET ROLE supabase_auth_admin/hms_api/hms_dispatcher` — a test-harness
  limitation (postgres is not a member of those roles in the local stack), not a migration failure.
