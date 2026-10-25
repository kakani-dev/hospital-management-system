# ADR 0002 — Database per service on a shared cluster

- Status: Accepted (owner decision, this change)
- Date: 2026-10-22
- Scope: identity, patients, scheduling, and the YARP edge. The legacy all-in-one host is not a data owner.

> **Update 25 Oct 2026:** the same model now also covers `billing`, `inventory` and `privacy` (7 ACA apps). See docs/HANDOVER.md.

## Context

MediCore already runs as three services behind one edge, on one Supabase Postgres. Schemas
(`identity`, `patient`, `appointment`), row-level security, published `_v1` functions, and
`messaging.outbox` are in place. Until this decision, each service login was a member of
`authenticated` and every request did `SET ROLE authenticated`. That role can read every schema the
policies allow, so a bug in one service could query another's tables. Ownership was a code rule,
not a database rule.

Splitting into three physical databases now would drop cross-schema foreign keys, force a copy of
the membership helpers into each database, and add a Supabase project per service.

## Decision

1. **One cluster, one database, one owner per schema.** `identity` is owned by the identity service,
   `patient` by patients, `appointment` by scheduling. `messaging` (outbox) and `audit` stay shared
   infrastructure: services touch them only as `hms_dispatcher` / `hms_mailer` or through security-definer
   triggers, never by selecting those tables as the service role.
2. **The service role is the session role.** `hms_<svc>_login` is `NOINHERIT` and a member of
   `hms_svc_<svc>` only (plus `anon`, so public identity routes can still `SET ROLE anon`).
   `hms_svc_<svc>` is **not** a member of `authenticated`. Authenticated requests
   `SET LOCAL ROLE hms_svc_<svc>`. The JWT claim `role` stays `authenticated` so `auth.uid()` and the
   published checks keep their meaning.
3. **Grants match the owner.** `hms_svc_<svc>` receives the same table, column, sequence, and
   function privileges `authenticated` has, and only on its schema. It is added to that schema's RLS
   policies. It has no privilege on another service's tables.
4. **Cross-service data is a contract.** A service may `EXECUTE` an explicitly granted function:
   the identity RLS helpers (`current_tenant_ids`, `has_tenant_role`, `has_tenant_permission`,
   `can_access_branch`), `identity.my_tenant_grant_v1`, `identity.my_active_context`, `auth.uid()`,
   and the published `_v1` functions in `docs/contracts/db.md` that this service is allowed to call.
   Those functions are `SECURITY DEFINER` and check the caller. There is no service-to-service HTTP
   on the request path.
5. **Migrations stay one chain, forward-only.** Files live in `supabase/migrations`. A new file is
   `<14-digit timestamp>_<identity|patients|scheduling|platform>_<what>.sql`, sets
   `lock_timeout` and `statement_timeout`, and is newer than every migration already on the base
   branch. A file that exists on the base branch is not edited. A migration or a service source file
   that touches another schema carries `-- cross-schema: approved` (or the same words in a code
   comment). CI enforces this (`.github/scripts/check-schema-ownership.sh`,
   `.github/scripts/check-migration-versions.sh`).
6. **Physical databases are a later split, not the default.** Move a schema to its own Postgres only
   when that domain needs different scale, retention, or a regulated boundary. The cost is: replace
   foreign keys with the `_v1` checks plus outbox events, replicate the membership helpers (or call
   identity for them), and pay for another Supabase project. The grants and contracts in this ADR
   are the seam that makes that split possible without rewriting the services.

`authenticated` keeps its current grants so the legacy `hms_api_login` host keeps working until it
is stopped. That host is not granted `hms_svc_*`. Applying migration `20261022140000` before the
new images are deployed breaks older service images, because they `SET ROLE authenticated`. The
cutover order is in `docs/runbooks/monolith-cutover.md`. This repository change does not apply the
migration to hosted Supabase and does not change the App Service.

## Consequences

- A compromised or buggy service process cannot `SELECT` another schema, even if it has a user's JWT.
- New tables need an explicit grant to the owning `hms_svc_*` role and a policy that includes it.
  Copying "whatever `authenticated` has" was a one-time migration, not a default privilege.
- Foreign keys across schemas remain. They are enforced by the database owner, not by the service
  role's grants. They are dropped only if a schema moves to another database.
- `anon` can still be assumed by every service login. `anon` has no HMS table grants; public
  functions stay limited to the identity routes that already allow it.
