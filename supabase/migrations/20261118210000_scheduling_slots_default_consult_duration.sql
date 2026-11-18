-- #317: default GET /slots length is the configured new_consult duration (branch
-- override, else the visit type), not the schedule grid and not a hard-coded value.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function appointment.effective_consult_duration_minutes(p_tenant_id uuid, p_branch_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(o.duration_minutes, t.duration_minutes)::integer
    from appointment.visit_types t
    left join appointment.visit_type_overrides o
      on o.tenant_id = t.tenant_id
     and o.visit_type_id = t.id
     and o.branch_id = p_branch_id
     and o.is_active and not o.is_deleted
   where t.tenant_id = p_tenant_id
     and t.code = 'new_consult'
     and t.is_active and not t.is_deleted
   limit 1;
$$;

revoke all on function appointment.effective_consult_duration_minutes(uuid, uuid) from public, anon;
grant execute on function appointment.effective_consult_duration_minutes(uuid, uuid) to authenticated, service_role, hms_svc_scheduling;
