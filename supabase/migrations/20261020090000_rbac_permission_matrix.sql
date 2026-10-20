-- RBAC (ADR 0001): role -> permission matrix mirrored in the database.
-- The API checks permissions (Hms.SharedKernel.Tenancy.HmsPermissions); RLS and the writer
-- functions below use the SAME matrix through identity.has_tenant_permission(), so a direct
-- PostgREST call cannot do more than the API allows. Doctors and nurses lose patient
-- create/edit; doctors and nurses lose appointment booking (they keep status updates, which the
-- API narrows further: nurse no-show/check-in, doctor no-show on their own appointments only).
-- Additive + policy replacement only; no data is changed.

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table identity.role_permissions (
  role text not null check (role in ('tenant_admin','doctor','nurse','receptionist','billing','pharmacist','lab_technician','viewer')),
  permission text not null check (permission ~ '^[a-z_]+\.[a-z_]+$'),
  created_on timestamptz not null default now(),
  created_by uuid not null,
  updated_on timestamptz not null default now(),
  updated_by uuid not null,
  is_deleted boolean not null default false,
  primary key (role, permission)
);
create trigger role_permissions_audit_columns before insert or update on identity.role_permissions
  for each row execute function audit.stamp_audit_columns();
comment on table identity.role_permissions is
  'RBAC matrix (ADR 0001). Must equal HmsPermissions.ByRole in the API (a unit test compares them). Read-only reference data.';
alter table identity.role_permissions enable row level security;
create policy role_permissions_select_all on identity.role_permissions for select to authenticated using (not is_deleted);
revoke all on identity.role_permissions from public, anon, authenticated;
grant select on identity.role_permissions to authenticated, service_role;

insert into identity.role_permissions (role, permission) values
  ('tenant_admin', 'settings.view'),
  ('tenant_admin', 'settings.manage'),
  ('tenant_admin', 'branches.view'),
  ('tenant_admin', 'branches.manage'),
  ('tenant_admin', 'members.manage'),
  ('tenant_admin', 'practitioners.view'),
  ('tenant_admin', 'practitioners.manage'),
  ('tenant_admin', 'patients.view'),
  ('tenant_admin', 'patients.create'),
  ('tenant_admin', 'patients.edit'),
  ('tenant_admin', 'patients.delete'),
  ('tenant_admin', 'patients.restore'),
  ('tenant_admin', 'appointments.view'),
  ('tenant_admin', 'appointments.book'),
  ('tenant_admin', 'appointments.reschedule'),
  ('tenant_admin', 'appointments.cancel'),
  ('tenant_admin', 'appointments.check_in'),
  ('tenant_admin', 'appointments.no_show'),
  ('tenant_admin', 'queue.view'),
  ('tenant_admin', 'queue.manage'),
  ('receptionist', 'settings.view'),
  ('receptionist', 'branches.view'),
  ('receptionist', 'practitioners.view'),
  ('receptionist', 'patients.view'),
  ('receptionist', 'patients.create'),
  ('receptionist', 'patients.edit'),
  ('receptionist', 'patients.delete'),
  ('receptionist', 'appointments.view'),
  ('receptionist', 'appointments.book'),
  ('receptionist', 'appointments.reschedule'),
  ('receptionist', 'appointments.cancel'),
  ('receptionist', 'appointments.check_in'),
  ('receptionist', 'appointments.no_show'),
  ('receptionist', 'queue.view'),
  ('receptionist', 'queue.manage'),
  ('nurse', 'settings.view'),
  ('nurse', 'branches.view'),
  ('nurse', 'practitioners.view'),
  ('nurse', 'patients.view'),
  ('nurse', 'appointments.view'),
  ('nurse', 'appointments.check_in'),
  ('nurse', 'appointments.no_show'),
  ('nurse', 'queue.view'),
  ('nurse', 'queue.manage'),
  ('doctor', 'settings.view'),
  ('doctor', 'branches.view'),
  ('doctor', 'practitioners.view'),
  ('doctor', 'patients.view'),
  ('doctor', 'appointments.view'),
  ('doctor', 'appointments.no_show_own'),
  ('doctor', 'queue.view'),
  ('doctor', 'queue.consult_own'),
  ('billing', 'settings.view'),
  ('billing', 'branches.view'),
  ('billing', 'practitioners.view'),
  ('billing', 'patients.view'),
  ('billing', 'appointments.view'),
  ('pharmacist', 'settings.view'),
  ('pharmacist', 'branches.view'),
  ('pharmacist', 'practitioners.view'),
  ('lab_technician', 'settings.view'),
  ('lab_technician', 'branches.view'),
  ('lab_technician', 'practitioners.view'),
  ('viewer', 'settings.view'),
  ('viewer', 'branches.view'),
  ('viewer', 'practitioners.view');

-- True when the caller holds, in p_tenant_id, an active membership whose role grants p_permission.
create or replace function identity.has_tenant_permission(p_tenant_id uuid, p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select identity.has_tenant_role(
    p_tenant_id,
    coalesce((select array_agg(rp.role) from identity.role_permissions rp where rp.permission = p_permission and not rp.is_deleted), array[]::text[]))
$$;
revoke all on function identity.has_tenant_permission(uuid, text) from public, anon;
grant execute on function identity.has_tenant_permission(uuid, text) to authenticated, service_role;

-- ------------------------------------------------------------- patients ----
drop policy patients_insert_registry_writers on patient.patients;
create policy patients_insert_registry_writers on patient.patients
  for insert to authenticated
  with check (identity.has_tenant_permission(tenant_id, 'patients.create')
              and identity.can_access_branch(tenant_id, registered_branch_id));

drop policy patients_update_registry_writers on patient.patients;
create policy patients_update_registry_writers on patient.patients
  for update to authenticated
  using (not is_deleted
         and identity.has_tenant_permission(tenant_id, 'patients.edit')
         and identity.can_access_branch(tenant_id, registered_branch_id))
  with check (identity.has_tenant_permission(tenant_id, 'patients.edit')
              and identity.can_access_branch(tenant_id, registered_branch_id));

create or replace function patient.set_patient_phones(
  p_patient_id uuid, p_phone text, p_whatsapp_same boolean, p_whatsapp text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p record;
  v_wa text;
begin
  select p.id, p.tenant_id, p.registered_branch_id, p.is_deleted into v_p
  from patient.patients p where p.id = p_patient_id
  for update;
  if v_p.id is null or v_p.tenant_id not in (select identity.current_tenant_ids()) or v_p.is_deleted then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_permission(v_p.tenant_id, 'patients.edit')
     or not identity.can_access_branch(v_p.tenant_id, v_p.registered_branch_id) then
    raise exception 'not permitted to edit this patient' using errcode = '42501';
  end if;
  if p_phone is not null and p_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'phone must be E.164' using errcode = '22023';
  end if;
  if p_whatsapp is not null and p_whatsapp !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'whatsapp must be E.164' using errcode = '22023';
  end if;
  if coalesce(p_whatsapp_same, false) and p_phone is null then
    raise exception 'whatsapp same as phone needs a phone number' using errcode = '22023';
  end if;

  v_wa := case when coalesce(p_whatsapp_same, false) then p_phone else p_whatsapp end;

  -- 1. soft-delete every live row that is not needed, or whose flags change (a changed row is
  --    replaced, never re-flagged in place: swaps would trip the one-primary / one-WhatsApp keys)
  update patient.patient_phones
     set is_deleted = true
   where patient_id = v_p.id and not is_deleted
     and (is_primary is distinct from (phone_e164 is not distinct from p_phone)
          or is_whatsapp is distinct from (phone_e164 is not distinct from v_wa));
  -- 2. insert what is missing
  if p_phone is not null and not exists (
      select 1 from patient.patient_phones where patient_id = v_p.id and not is_deleted and phone_e164 = p_phone) then
    insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary, is_whatsapp)
    values (v_p.tenant_id, v_p.id, p_phone, true, coalesce(p_phone = v_wa, false));
  end if;
  if v_wa is not null and v_wa is distinct from p_phone and not exists (
      select 1 from patient.patient_phones where patient_id = v_p.id and not is_deleted and phone_e164 = v_wa) then
    insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary, is_whatsapp)
    values (v_p.tenant_id, v_p.id, v_wa, false, true);
  end if;

  -- deprecated mirror (expand phase)
  update patient.patients set phone = p_phone where id = v_p.id and phone is distinct from p_phone;
end;
$$;

-- --------------------------------------------------------- appointments ----
drop policy appointments_insert_writers on appointment.appointments;
create policy appointments_insert_writers on appointment.appointments
  for insert to authenticated
  with check (identity.has_tenant_permission(tenant_id, 'appointments.book')
              and identity.can_access_branch(tenant_id, branch_id));

drop policy appointments_update_writers on appointment.appointments;
create policy appointments_update_writers on appointment.appointments
  for update to authenticated
  using ((identity.has_tenant_permission(tenant_id, 'appointments.reschedule')
          or identity.has_tenant_permission(tenant_id, 'appointments.cancel')
          or identity.has_tenant_permission(tenant_id, 'appointments.no_show')
          or identity.has_tenant_permission(tenant_id, 'appointments.no_show_own'))
         and identity.can_access_branch(tenant_id, branch_id))
  with check ((identity.has_tenant_permission(tenant_id, 'appointments.reschedule')
               or identity.has_tenant_permission(tenant_id, 'appointments.cancel')
               or identity.has_tenant_permission(tenant_id, 'appointments.no_show')
               or identity.has_tenant_permission(tenant_id, 'appointments.no_show_own'))
              and identity.can_access_branch(tenant_id, branch_id));
