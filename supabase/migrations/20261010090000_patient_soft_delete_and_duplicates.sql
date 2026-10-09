-- =============================================================================
-- Sprint 2 / Migration 11: patient soft delete, phone/DOB search indexes, duplicate detection.
-- Contract: /workspace/SPRINT2-CONTRACT.md §1 (D1-D3).
--   * Soft delete / restore ONLY through patient.soft_delete_patient() / restore_patient()
--     (client column grant on deleted_at revoked). deleted_by / deletion_reason recorded.
--   * Deleted rows are visible to tenant_admin only; deleted rows cannot be edited.
--   * MRN stays reserved after soft delete (unique (tenant_id, mrn) unchanged).
--   * patient.find_duplicate_patients(): advisory (never blocks), SECURITY INVOKER (RLS applies).
-- Out of scope: deferred PR #1 hardening (docs/backlog/pr1-db-hardening-draft.sql).
-- =============================================================================

alter table patient.patients
  add column deleted_by uuid,
  add column deletion_reason text;

alter table patient.patients
  add constraint patients_deletion_reason_length check (deletion_reason is null or length(deletion_reason) <= 500),
  -- legacy rows may carry deleted_at without deleted_by; a live row never carries deletion metadata
  add constraint patients_deleted_consistent check (deleted_at is not null or (deleted_by is null and deletion_reason is null));

comment on column patient.patients.deleted_by is 'Actor of the soft delete (patient.soft_delete_patient). Never client-written.';
comment on column patient.patients.deletion_reason is 'Optional reason given at soft delete (<= 500 chars).';

-- Soft delete is RPC-only from now on.
revoke update (deleted_at) on patient.patients from authenticated;

-- ---------------------------------------------------------------------- RLS ----
drop policy if exists patients_select_registry_roles on patient.patients;
create policy patients_select_registry_roles on patient.patients
  for select to authenticated
  using (
    identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing'])
    and (deleted_at is null or identity.has_tenant_role(tenant_id, array['tenant_admin']))
  );

drop policy if exists patients_update_registry_writers on patient.patients;
create policy patients_update_registry_writers on patient.patients
  for update to authenticated
  using (
    deleted_at is null
    and identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
  )
  with check (
    identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
    and identity.can_access_branch(tenant_id, registered_branch_id)
  );

-- ------------------------------------------------------------ phone search ----
create or replace function patient.normalize_phone(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case when length(x.d) >= 7 then right(x.d, 10) end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x
$$;
comment on function patient.normalize_phone(text) is
  'Digits only, last 10 digits; NULL when fewer than 7 digits. Use on both sides of a phone comparison.';

create index if not exists patients_tenant_phone_norm_idx
  on patient.patients (tenant_id, patient.normalize_phone(phone)) where deleted_at is null;
create index if not exists patients_tenant_dob_idx
  on patient.patients (tenant_id, date_of_birth) where deleted_at is null;
create index if not exists patients_tenant_name_dob_idx
  on patient.patients (tenant_id, lower(btrim(last_name)), lower(btrim(first_name)), date_of_birth) where deleted_at is null;

-- ---------------------------------------------------------- soft delete RPCs ----
-- Open appointments / queue entries (tables created by 20261010090100/090200) block the
-- delete with 55000; PL/pgSQL resolves those tables at call time.
create or replace function patient.soft_delete_patient(p_patient_id uuid, p_reason text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_p record;
begin
  if p_reason is not null and length(p_reason) > 500 then
    raise exception 'reason too long (max 500)' using errcode = '22023';
  end if;

  select p.id, p.tenant_id, p.registered_branch_id, p.deleted_at into v_p
  from patient.patients p where p.id = p_patient_id
  for update;

  if v_p.id is null or v_p.deleted_at is not null
     or not identity.has_tenant_role(v_p.tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing']) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;

  if not identity.has_tenant_role(v_p.tenant_id, array['tenant_admin', 'receptionist'])
     or not identity.can_access_branch(v_p.tenant_id, v_p.registered_branch_id) then
    raise exception 'not permitted to delete this patient' using errcode = '42501';
  end if;

  if exists (select 1 from appointment.appointments a
             where a.tenant_id = v_p.tenant_id and a.patient_id = v_p.id
               and a.status in ('booked', 'checked_in', 'in_consultation'))
     or exists (select 1 from appointment.queue_entries q
                where q.tenant_id = v_p.tenant_id and q.patient_id = v_p.id
                  and q.status in ('waiting', 'in_consultation')) then
    raise exception 'patient has open appointments or queue entries; cancel them first' using errcode = '55000';
  end if;

  update patient.patients
     set deleted_at = now(),
         deleted_by = auth.uid(),
         deletion_reason = nullif(btrim(p_reason), '')
   where id = v_p.id;
end;
$$;

create or replace function patient.restore_patient(p_patient_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_p record;
begin
  select p.id, p.tenant_id, p.deleted_at into v_p
  from patient.patients p where p.id = p_patient_id
  for update;

  if v_p.id is null
     or not identity.has_tenant_role(v_p.tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing']) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_p.tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can restore patients' using errcode = '42501';
  end if;
  if v_p.deleted_at is null then
    raise exception 'patient is not deleted' using errcode = 'P0002';
  end if;

  update patient.patients
     set deleted_at = null, deleted_by = null, deletion_reason = null
   where id = v_p.id;
end;
$$;

-- ------------------------------------------------------- duplicate detection ----
create or replace function patient.find_duplicate_patients(
  p_tenant_id uuid,
  p_first_name text,
  p_last_name text,
  p_date_of_birth date,
  p_phone text,
  p_exclude_id uuid default null)
returns table (
  patient_id uuid,
  mrn text,
  first_name text,
  last_name text,
  date_of_birth date,
  phone text,
  registered_branch_id uuid,
  match_reasons text[])
language sql
stable
security invoker
set search_path = ''
as $$
  select p.id, p.mrn, p.first_name, p.last_name, p.date_of_birth, p.phone, p.registered_branch_id,
         array_remove(array[case when m.by_name then 'name_dob' end, case when m.by_phone then 'phone' end], null)
  from patient.patients p
  cross join lateral (
    select
      coalesce(p_date_of_birth is not null and p.date_of_birth = p_date_of_birth
        and lower(btrim(p.last_name)) = lower(btrim(p_last_name))
        and lower(btrim(p.first_name)) = lower(btrim(p_first_name)), false) as by_name,
      coalesce(patient.normalize_phone(p.phone) = patient.normalize_phone(p_phone), false) as by_phone
  ) m
  where p.tenant_id = p_tenant_id
    and p.deleted_at is null
    and (p_exclude_id is null or p.id <> p_exclude_id)
    and (m.by_name or m.by_phone)
  order by (m.by_name and m.by_phone) desc, p.last_name, p.first_name, p.mrn
  limit 20
$$;

revoke all on function patient.normalize_phone(text) from public, anon;
revoke all on function patient.soft_delete_patient(uuid, text) from public, anon;
revoke all on function patient.restore_patient(uuid) from public, anon;
revoke all on function patient.find_duplicate_patients(uuid, text, text, date, text, uuid) from public, anon;
grant execute on function patient.normalize_phone(text) to authenticated, service_role;
grant execute on function patient.soft_delete_patient(uuid, text) to authenticated, service_role;
grant execute on function patient.restore_patient(uuid) to authenticated, service_role;
grant execute on function patient.find_duplicate_patients(uuid, text, text, date, text, uuid) to authenticated, service_role;
