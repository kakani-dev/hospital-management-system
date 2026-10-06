-- =============================================================================
-- Sprint 0 / Migration 5: append-only audit log
-- =============================================================================

create table audit.audit_log (
  id           bigint generated always as identity primary key,
  tenant_id    uuid not null,
  schema_name  text not null,
  table_name   text not null,
  record_id    uuid,
  action       text not null,
  old_data     jsonb,
  new_data     jsonb,
  changed_by   uuid,
  changed_at   timestamptz not null default now(),
  tx_id        bigint not null default txid_current(),
  constraint audit_log_action_valid check (action in ('INSERT', 'UPDATE', 'DELETE'))
);

comment on table audit.audit_log is
  'Append-only row-change log. Written only by audit.log_row_change(). NOTE: contains row snapshots (PHI) — same access rules as source data.';

create index audit_log_tenant_time_idx on audit.audit_log (tenant_id, changed_at desc);
create index audit_log_tenant_record_idx on audit.audit_log (tenant_id, table_name, record_id);

create or replace function audit.log_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_tenant uuid;
begin
  v_tenant := coalesce(
    (v_row ->> 'tenant_id')::uuid,
    case when tg_table_schema = 'identity' and tg_table_name = 'tenants' then (v_row ->> 'id')::uuid end
  );

  insert into audit.audit_log (tenant_id, schema_name, table_name, record_id, action, old_data, new_data, changed_by)
  values (
    v_tenant,
    tg_table_schema,
    tg_table_name,
    (v_row ->> 'id')::uuid,
    tg_op,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end,
    auth.uid()
  );
  return null; -- AFTER trigger
end;
$$;

create or replace function audit.prevent_audit_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'audit.audit_log is append-only' using errcode = '42501';
end;
$$;

create trigger audit_log_no_update_delete before update or delete on audit.audit_log
  for each row execute function audit.prevent_audit_mutation();
create trigger audit_log_no_truncate before truncate on audit.audit_log
  for each statement execute function audit.prevent_audit_mutation();

create trigger tenants_audit_log after insert or update or delete on identity.tenants
  for each row execute function audit.log_row_change();
create trigger branches_audit_log after insert or update or delete on identity.branches
  for each row execute function audit.log_row_change();
create trigger memberships_audit_log after insert or update or delete on identity.memberships
  for each row execute function audit.log_row_change();
create trigger patients_audit_log after insert or update or delete on patient.patients
  for each row execute function audit.log_row_change();
