-- cross-schema: approved (published v1 contract, docs/contracts/db.md; consumer: billing.
-- Reads appointment.appointments only. No patient name, no practitioner name.)
-- The reference billing may hold for an appointment: ids and status only.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- cross-schema: approved (published v1 contract, docs/contracts/db.md; consumer: billing)
create or replace function appointment.appointment_billing_ref_v1(p_tenant_id uuid, p_appointment_id uuid)
returns table (patient_id uuid, branch_id uuid, practitioner_id uuid, status text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon'))
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return query
  select a.patient_id, a.branch_id, a.practitioner_id, a.status
  from appointment.appointments a
  where a.tenant_id = p_tenant_id
    and a.id = p_appointment_id
    and not a.is_deleted;
end;
$$;

revoke all on function appointment.appointment_billing_ref_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function appointment.appointment_billing_ref_v1(uuid, uuid) to service_role, hms_svc_billing;

comment on function appointment.appointment_billing_ref_v1(uuid, uuid) is
  'v1 (published by scheduling): patient_id, branch_id, practitioner_id, status for one appointment. No names. Empty when missing. Additive changes only.';
