# TODO (tracked): contract step for PR #4's expand migrations

Status: **open**, not scheduled. Owner: DB. Raised by the DB re-review (N2) and code review (MAJ-1) of PR #4.
PR #4 (`20261012090000`, `20261012090100`) only *expands* the schema; this file is the tracking item for the
follow-up migration that removes the compatibility pieces. Do not write it until every gate below is ticked.

## What the contract migration drops

1. `created_at` / `updated_at` on every identity/patient/appointment table, and the `'legacy_at'` argument of the
   `*_audit_columns` triggers (`audit.stamp_audit_columns`). Until then the trigger derives them one-way from
   `created_on` / `updated_on`; values written to the legacy columns are ignored.
2. `identity.branches.timezone` (the NOT NULL mirror of the effective zone, kept by `identity.guard_time_zone` and the
   `tenants_time_zone_cascade` trigger), its legacy `update (timezone)` / `insert (timezone)` grants to `authenticated`,
   and the legacy-write branch of `identity.guard_time_zone`. `timezone_override` + `identity.branch_time_zone_v1`
   become the only source.

## Gates (all required)

- [ ] Every deployed service (monolith API, identity service, any worker) reads/writes `*_on` and `timezone_override`
      only. Check: `rg -n "created_at|updated_at|\"timezone\"" backend services` returns no column mappings.
- [ ] The hosted DB has run PR #4 for at least one full release, and the pre-PR-4 API build is no longer deployable
      (rollback target moved past it).
- [ ] `audit.audit_log` consumers (reports, exports) read both key names: old rows carry `created_at`/`updated_at`
      in `old_data`/`new_data`, new rows `created_on`/`updated_on`. Rows are never rewritten.
- [ ] No `pg_depend` / view / function body references the legacy columns
      (`select … from pg_proc where prosrc ~ '(created|updated)_at|branches\.timezone'`).
- [ ] The migration sets `lock_timeout` / `statement_timeout` and follows the hosted runbook (§9 of
      `deploy-sprint-2-hosted.md`).

## Not in scope

`messaging.outbox` and `audit.audit_log` stay exempt from the audit columns (they are append-only system tables).
