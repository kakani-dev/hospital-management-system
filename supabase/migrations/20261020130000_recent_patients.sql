-- Recent patients (GET /api/v1/patients?sort=recent): newest first by the latest of the patient's
-- registration (patient.patients.created_on) and their latest booking (appointment.appointments
-- .created_on). The patients service reads its own table under RLS and gets the booking side from
-- the appointment schema's published function below (no cross-schema table reads, R3).
-- Additive only: one function, two indexes. No data is changed.

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create index if not exists patients_tenant_created_idx
  on patient.patients (tenant_id, created_on desc) where not is_deleted;
create index if not exists appointments_tenant_created_idx
  on appointment.appointments (tenant_id, created_on desc) include (patient_id) where not is_deleted;

-- Latest booking time per patient in one of the caller's tenants, newest first, at most 500 rows.
-- Callers need patients.view in that tenant (same matrix as the API); others get nothing. Only
-- patient ids and timestamps leave the appointment schema. Trusted callers without a user
-- (service_role) skip the checks.
-- cross-schema: approved (published v1 contract, docs/contracts/db.md; consumer: patients)
create or replace function appointment.patient_last_booked_v1(p_tenant_id uuid, p_limit integer)
returns table (patient_id uuid, last_booked_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_tenant_id is null
     or ((auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon'))
         and (p_tenant_id not in (select identity.current_tenant_ids())
              or not identity.has_tenant_permission(p_tenant_id, 'patients.view'))) then
    return;
  end if;

  return query
  select a.patient_id, max(a.created_on) as last_booked_at
  from appointment.appointments a
  where a.tenant_id = p_tenant_id and not a.is_deleted
  group by a.patient_id
  order by 2 desc, 1
  limit least(greatest(coalesce(p_limit, 25), 1), 500);
end;
$$;
revoke all on function appointment.patient_last_booked_v1(uuid, integer) from public, anon;
grant execute on function appointment.patient_last_booked_v1(uuid, integer) to authenticated, service_role;
comment on function appointment.patient_last_booked_v1(uuid, integer) is
  'v1 (published by appointments): latest booking created_on per patient in one of the caller''s tenants (patients.view), newest first, <=500 rows. Additive changes only.';
