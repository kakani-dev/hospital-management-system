-- cross-schema: approved (audit.stamp_audit_columns stays the shared writer trigger.
-- Hosted Supabase does not let a custom role use schema auth, so auth.uid() inside
-- the invoker stamp fails for hms_svc_billing. The actor is resolved here, as the
-- migration role, which already has that access. The stamp stays SECURITY INVOKER
-- so its current_user soft-delete check is unchanged.)
-- Session actor for audit stamps. Callable by service roles; returns only this session's id.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

create or replace function audit.session_actor_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    auth.uid(),
    nullif(pg_catalog.current_setting('hms.actor_id', true), '')::uuid)
$$;

revoke all on function audit.session_actor_id() from public;
-- USAGE resolves the function. It does not grant audit.audit_log.
grant usage on schema audit to
  authenticated, service_role, hms_api,
  hms_svc_identity, hms_svc_patients, hms_svc_scheduling, hms_svc_billing;
grant execute on function audit.session_actor_id() to
  authenticated, service_role, hms_api,
  hms_svc_identity, hms_svc_patients, hms_svc_scheduling, hms_svc_billing;

comment on function audit.session_actor_id() is
  'Actor for this session: auth.uid(), else hms.actor_id. Security definer so service roles can stamp rows without USAGE on schema auth.';

create or replace function audit.stamp_audit_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
-- Trigger arguments:
--   'legacy_at'            table still has created_at/updated_at (expand phase): derive them from
--                          created_on/updated_on (one-way; values written to the legacy pair are ignored)
--   'generated_is_deleted' is_deleted is generated from deleted_at (patients): never assign it, guard
--                          deleted_at instead
declare
  v_actor uuid := coalesce(
    audit.session_actor_id(),
    '00000000-0000-4000-8000-00000000005e'::uuid);  -- audit.system_actor()
  v_legacy boolean := 'legacy_at' = any (coalesce(tg_argv, '{}'::text[]));
  v_generated boolean := 'generated_is_deleted' = any (coalesce(tg_argv, '{}'::text[]));
  v_owner name;
begin
  if tg_op = 'INSERT' then
    -- client values are never trusted: every column is overwritten
    new.created_on := now();
    new.created_by := v_actor;
    new.updated_on := new.created_on;
    new.updated_by := v_actor;
    if not v_generated then
      new.is_deleted := false;                         -- rows are never born deleted
    end if;
  elsif tg_op = 'UPDATE' then
    new.created_on := old.created_on;
    new.created_by := old.created_by;
    new.updated_on := now();
    new.updated_by := v_actor;
    -- soft-delete state fails CLOSED (review S3, re-review R1/R2): only the table owner, i.e. the
    -- SECURITY DEFINER soft-delete/restore functions, may change it. No session setting unlocks it.
    -- On generated tables the state lives in deleted_at (read through to_jsonb: shared function).
    if (not v_generated and new.is_deleted is distinct from old.is_deleted)
       or (v_generated and (pg_catalog.to_jsonb(new) ->> 'deleted_at') is distinct from (pg_catalog.to_jsonb(old) ->> 'deleted_at')) then
      select pg_catalog.pg_get_userbyid(c.relowner) into v_owner from pg_catalog.pg_class c where c.oid = tg_relid;
      if current_user in ('authenticated', 'anon') or current_user <> v_owner then
        raise exception 'is_deleted can only be changed through the soft-delete / restore functions'
          using errcode = '42501';
      end if;
    end if;
  end if;
  if v_legacy then
    new.created_at := new.created_on;
    new.updated_at := new.updated_on;
  end if;
  return new;
end;
$$;

revoke all on function audit.stamp_audit_columns() from public;
