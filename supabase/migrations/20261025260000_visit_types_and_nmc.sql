-- cross-schema: approved (RLS uses identity.current_tenant_ids, identity.has_tenant_role and
-- identity.can_access_branch. Billing reads credentials and the snapshotted consult fee only
-- through appointment.practitioner_credential_v1 and appointment.appointment_consultation_fee_v1.
-- No table reads outside appointment.)
-- Visit-type master (tenant defaults, optional branch overrides) and NMC / council fields on
-- practitioners, plus a per-tenant department master. Tenant id is never taken from the client.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ---------------------------------------------------------------- departments ----
create table appointment.departments (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references identity.tenants (id) on delete restrict,
  name        text not null,
  is_active   boolean not null default true,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  constraint departments_tenant_id_id_key unique (tenant_id, id),
  constraint departments_name_len check (length(btrim(name)) between 1 and 80)
);
create unique index departments_live_name_key
  on appointment.departments (tenant_id, lower(name)) where not is_deleted;
comment on table appointment.departments is
  'Per-tenant department master. Practitioners point at one row. Admins edit; every member may read.';

-- --------------------------------------------------------------- visit types ----
create table appointment.visit_types (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references identity.tenants (id) on delete restrict,
  code                  text not null,
  name                  text not null,
  default_fee_paise     bigint not null,
  duration_minutes      smallint not null,
  follow_up_valid_days  smallint,
  follow_up_fee_paise   bigint,
  sort_order            smallint not null default 0,
  is_active             boolean not null default true,
  created_on            timestamptz not null default now(),
  created_by            uuid not null,
  updated_on            timestamptz not null default now(),
  updated_by            uuid not null,
  is_deleted            boolean not null default false,
  constraint visit_types_tenant_id_id_key unique (tenant_id, id),
  constraint visit_types_code_format check (code ~ '^[a-z][a-z0-9_]{1,31}$'),
  constraint visit_types_name_len check (length(btrim(name)) between 1 and 80),
  constraint visit_types_fee_nonneg check (default_fee_paise >= 0 and default_fee_paise <= 10000000000),
  constraint visit_types_duration check (duration_minutes between 5 and 240),
  constraint visit_types_window check (follow_up_valid_days is null or follow_up_valid_days between 0 and 366),
  constraint visit_types_follow_fee check (follow_up_fee_paise is null or (follow_up_fee_paise >= 0 and follow_up_fee_paise <= 10000000000))
);
create unique index visit_types_live_code_key
  on appointment.visit_types (tenant_id, code) where not is_deleted;
comment on table appointment.visit_types is
  'Tenant visit-type master. follow_up_valid_days is how long a later Follow-up of this visit stays free or reduced (follow_up_fee_paise; 0 = free). Null window means this visit opens no follow-up entitlement.';
comment on column appointment.visit_types.default_fee_paise is
  'Integer paise. Branch overrides and the booking snapshot live elsewhere; this is the hospital default.';

create table appointment.visit_type_overrides (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references identity.tenants (id) on delete restrict,
  visit_type_id         uuid not null,
  branch_id             uuid not null,
  fee_paise             bigint,
  duration_minutes      smallint,
  follow_up_valid_days  smallint,
  follow_up_fee_paise   bigint,
  is_active             boolean not null default true,
  created_on            timestamptz not null default now(),
  created_by            uuid not null,
  updated_on            timestamptz not null default now(),
  updated_by            uuid not null,
  is_deleted            boolean not null default false,
  constraint visit_type_overrides_type_same_tenant
    foreign key (tenant_id, visit_type_id) references appointment.visit_types (tenant_id, id) on delete cascade,
  constraint visit_type_overrides_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete cascade,
  constraint visit_type_overrides_tenant_id_id_key unique (tenant_id, id),
  constraint visit_type_overrides_fee check (fee_paise is null or (fee_paise >= 0 and fee_paise <= 10000000000)),
  constraint visit_type_overrides_duration check (duration_minutes is null or duration_minutes between 5 and 240),
  constraint visit_type_overrides_window check (follow_up_valid_days is null or follow_up_valid_days between 0 and 366),
  constraint visit_type_overrides_follow_fee check (follow_up_fee_paise is null or (follow_up_fee_paise >= 0 and follow_up_fee_paise <= 10000000000))
);
create unique index visit_type_overrides_live_key
  on appointment.visit_type_overrides (tenant_id, visit_type_id, branch_id) where not is_deleted;
comment on table appointment.visit_type_overrides is
  'Optional per-branch replacement. A null column inherits the tenant visit type. follow_up_valid_days 0 means this branch opens no follow-up window.';

-- ------------------------------------------------------- practitioner NMC fields ----
alter table appointment.practitioners
  add column registration_number text,
  add column council_name text,
  add column qualifications text,
  add column department_id uuid,
  add column phone text,
  add column email text,
  add constraint practitioners_department_same_tenant
    foreign key (tenant_id, department_id) references appointment.departments (tenant_id, id) on delete restrict,
  add constraint practitioners_registration_format check (
    registration_number is null or (
      length(registration_number) between 4 and 30
      and registration_number ~ '^[A-Z0-9][A-Z0-9./ -]{2,28}[A-Z0-9]$'
      and registration_number ~ '[0-9].*[0-9].*[0-9]')),
  add constraint practitioners_council_len check (council_name is null or length(btrim(council_name)) between 1 and 120),
  add constraint practitioners_qualifications_len check (qualifications is null or length(btrim(qualifications)) between 1 and 200),
  add constraint practitioners_phone_e164 check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'),
  add constraint practitioners_email_format check (
    email is null or (
      length(email) between 3 and 254
      and position('@' in email) > 1
      and email !~ '[[:space:]]'
      and email ~ '^[^@]+@[^@]+\.[^@]+$'));
create unique index practitioners_registration_live_key
  on appointment.practitioners (tenant_id, registration_number)
  where registration_number is not null and not is_deleted;
create index practitioners_department_idx on appointment.practitioners (tenant_id, department_id);
comment on column appointment.practitioners.registration_number is
  'NMC or State Medical Council registration, stored uppercase. Format check only: 4-30 characters, letters, digits, spaces, dots, slashes and hyphens, at least three digits. Not a live lookup of the NMC register.';

-- ---------------------------------------------------------- appointment snapshot ----
alter table appointment.appointments
  add column visit_type_id uuid,
  add column consultation_fee_paise bigint,
  add column granted_follow_up_days smallint,
  add column granted_follow_up_fee_paise bigint,
  add constraint appointments_visit_type_same_tenant
    foreign key (tenant_id, visit_type_id) references appointment.visit_types (tenant_id, id) on delete restrict,
  add constraint appointments_consultation_fee_nonneg check (
    consultation_fee_paise is null or (consultation_fee_paise >= 0 and consultation_fee_paise <= 10000000000)),
  add constraint appointments_granted_window check (
    granted_follow_up_days is null or granted_follow_up_days between 0 and 366),
  add constraint appointments_granted_follow_fee check (
    granted_follow_up_fee_paise is null or (granted_follow_up_fee_paise >= 0 and granted_follow_up_fee_paise <= 10000000000));
create index appointments_visit_type_idx on appointment.appointments (tenant_id, visit_type_id)
  where visit_type_id is not null;
comment on column appointment.appointments.consultation_fee_paise is
  'Fee snapshot in paise at booking (visit type, branch override, and a free or reduced follow-up inside the prior visit window). Billing reads it via appointment.appointment_consultation_fee_v1. This column does not post a bill line.';
comment on column appointment.appointments.granted_follow_up_days is
  'Follow-up window copied from the visit type (and branch override) at booking. Later edits or a soft delete of the type do not change it. Null opens no window; 0 is an explicit none and closes an older window.';
comment on column appointment.appointments.granted_follow_up_fee_paise is
  'Follow-up fee copied at booking. Null means a later Follow-up uses the Follow-up type fee; 0 is free. Not rewritten when the type changes.';

-- ---------------------------------------------------------------- defaults for existing tenants ----
create or replace function appointment.ensure_default_visit_types(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_tenant_id is null then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if auth.uid() is not null
     and p_tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from identity.tenants t where t.id = p_tenant_id and not t.is_deleted) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;

  insert into appointment.visit_types (
    tenant_id, code, name, default_fee_paise, duration_minutes, follow_up_valid_days, follow_up_fee_paise, sort_order)
  values
    (p_tenant_id, 'new_consult', 'New consult', 50000, 30, 7, 0, 1),
    (p_tenant_id, 'follow_up', 'Follow-up', 20000, 15, null, null, 2),
    (p_tenant_id, 'review', 'Review', 30000, 20, 14, 10000, 3),
    (p_tenant_id, 'emergency', 'Emergency', 80000, 20, null, null, 4),
    (p_tenant_id, 'teleconsult', 'Teleconsult', 40000, 15, 3, 0, 5)
  on conflict (tenant_id, code) where not is_deleted do nothing;
end;
$$;
comment on function appointment.ensure_default_visit_types(uuid) is
  'Inserts the five default visit types when the tenant has none. Idempotent. The tenant id must be the caller''s session tenant.';
revoke all on function appointment.ensure_default_visit_types(uuid) from public, anon;
grant execute on function appointment.ensure_default_visit_types(uuid) to authenticated, service_role, hms_svc_scheduling;

select appointment.ensure_default_visit_types(id) from identity.tenants;

-- ------------------------------------------------------------------------- RLS ----
alter table appointment.departments enable row level security;
alter table appointment.visit_types enable row level security;
alter table appointment.visit_type_overrides enable row level security;

revoke all on appointment.departments, appointment.visit_types, appointment.visit_type_overrides
  from public, anon, authenticated;

create policy departments_select_member on appointment.departments
  for select to authenticated, hms_svc_scheduling
  using (tenant_id in (select identity.current_tenant_ids())
         and (not is_deleted or identity.has_tenant_role(tenant_id, array['tenant_admin'])));
create policy departments_insert_admin on appointment.departments
  for insert to authenticated, hms_svc_scheduling
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));
create policy departments_update_admin on appointment.departments
  for update to authenticated, hms_svc_scheduling
  using (not is_deleted and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));

create policy visit_types_select_member on appointment.visit_types
  for select to authenticated, hms_svc_scheduling
  using (tenant_id in (select identity.current_tenant_ids())
         and (not is_deleted or identity.has_tenant_role(tenant_id, array['tenant_admin'])));
create policy visit_types_insert_admin on appointment.visit_types
  for insert to authenticated, hms_svc_scheduling
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));
create policy visit_types_update_admin on appointment.visit_types
  for update to authenticated, hms_svc_scheduling
  using (not is_deleted and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));

create policy visit_type_overrides_select_member on appointment.visit_type_overrides
  for select to authenticated, hms_svc_scheduling
  using (tenant_id in (select identity.current_tenant_ids())
         and (not is_deleted or identity.has_tenant_role(tenant_id, array['tenant_admin'])));
create policy visit_type_overrides_insert_admin on appointment.visit_type_overrides
  for insert to authenticated, hms_svc_scheduling
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin'])
              and identity.can_access_branch(tenant_id, branch_id));
create policy visit_type_overrides_update_admin on appointment.visit_type_overrides
  for update to authenticated, hms_svc_scheduling
  using (not is_deleted and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin'])
              and identity.can_access_branch(tenant_id, branch_id));

grant select on appointment.departments, appointment.visit_types, appointment.visit_type_overrides
  to authenticated, hms_svc_scheduling;
grant insert (id, tenant_id, name, is_active) on appointment.departments to authenticated, hms_svc_scheduling;
grant update (name, is_active) on appointment.departments to authenticated, hms_svc_scheduling;
grant insert (id, tenant_id, code, name, default_fee_paise, duration_minutes, follow_up_valid_days, follow_up_fee_paise, sort_order, is_active)
  on appointment.visit_types to authenticated, hms_svc_scheduling;
grant update (name, default_fee_paise, duration_minutes, follow_up_valid_days, follow_up_fee_paise, sort_order, is_active)
  on appointment.visit_types to authenticated, hms_svc_scheduling;
grant insert (id, tenant_id, visit_type_id, branch_id, fee_paise, duration_minutes, follow_up_valid_days, follow_up_fee_paise, is_active)
  on appointment.visit_type_overrides to authenticated, hms_svc_scheduling;
grant update (fee_paise, duration_minutes, follow_up_valid_days, follow_up_fee_paise, is_active)
  on appointment.visit_type_overrides to authenticated, hms_svc_scheduling;

grant insert (registration_number, council_name, qualifications, department_id, phone, email)
  on appointment.practitioners to authenticated, hms_svc_scheduling;
grant update (registration_number, council_name, qualifications, department_id, phone, email)
  on appointment.practitioners to authenticated, hms_svc_scheduling;
grant insert (visit_type_id, consultation_fee_paise, granted_follow_up_days, granted_follow_up_fee_paise)
  on appointment.appointments to authenticated, hms_svc_scheduling;

grant all on appointment.departments, appointment.visit_types, appointment.visit_type_overrides to service_role;

create trigger departments_audit_columns before insert or update on appointment.departments
  for each row execute function audit.stamp_audit_columns();
create trigger departments_tenant_immutable before update on appointment.departments
  for each row execute function audit.prevent_tenant_change();
create trigger departments_audit_log after insert or update or delete on appointment.departments
  for each row execute function audit.log_row_change();

create trigger visit_types_audit_columns before insert or update on appointment.visit_types
  for each row execute function audit.stamp_audit_columns();
create trigger visit_types_tenant_immutable before update on appointment.visit_types
  for each row execute function audit.prevent_tenant_change();
create trigger visit_types_audit_log after insert or update or delete on appointment.visit_types
  for each row execute function audit.log_row_change();

create trigger visit_type_overrides_audit_columns before insert or update on appointment.visit_type_overrides
  for each row execute function audit.stamp_audit_columns();
create trigger visit_type_overrides_tenant_immutable before update on appointment.visit_type_overrides
  for each row execute function audit.prevent_tenant_change();
create trigger visit_type_overrides_audit_log after insert or update or delete on appointment.visit_type_overrides
  for each row execute function audit.log_row_change();

-- ------------------------------------------------ published reads for later bills ----
-- cross-schema: approved (published v1 contract, docs/contracts/db.md; consumer: billing)
create or replace function appointment.practitioner_credential_v1(p_tenant_id uuid, p_practitioner_id uuid)
returns table (
  registration_number text,
  council_name text,
  qualifications text,
  specialty text,
  department_name text,
  phone text,
  email text)
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
  select pr.registration_number, pr.council_name, pr.qualifications, pr.specialty,
         d.name, pr.phone, pr.email
  from appointment.practitioners pr
  left join appointment.departments d
    on d.tenant_id = pr.tenant_id and d.id = pr.department_id and not d.is_deleted
  where pr.tenant_id = p_tenant_id
    and pr.id = p_practitioner_id
    and not pr.is_deleted;
end;
$$;
revoke all on function appointment.practitioner_credential_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function appointment.practitioner_credential_v1(uuid, uuid) to service_role, hms_svc_billing;
comment on function appointment.practitioner_credential_v1(uuid, uuid) is
  'v1 (published by scheduling): council registration and contact for one practitioner, for later prescriptions and bills. Empty when missing. No patient data.';

-- cross-schema: approved (published v1 contract, docs/contracts/db.md; consumer: billing)
create or replace function appointment.appointment_consultation_fee_v1(p_tenant_id uuid, p_appointment_id uuid)
returns table (visit_type_id uuid, visit_type_code text, consultation_fee_paise bigint)
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
  select a.visit_type_id, vt.code, a.consultation_fee_paise
  from appointment.appointments a
  left join appointment.visit_types vt
    on vt.tenant_id = a.tenant_id and vt.id = a.visit_type_id and not vt.is_deleted
  where a.tenant_id = p_tenant_id
    and a.id = p_appointment_id
    and not a.is_deleted;
end;
$$;
revoke all on function appointment.appointment_consultation_fee_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function appointment.appointment_consultation_fee_v1(uuid, uuid) to service_role, hms_svc_billing;
comment on function appointment.appointment_consultation_fee_v1(uuid, uuid) is
  'v1 (published by scheduling): visit type and the paise fee snapshotted at booking. Empty when the appointment is missing. Does not post a bill line. A soft-deleted visit type leaves the code null and still returns the snapshotted fee.';

-- Soft delete does not cascade to appointments (the FK is ON DELETE RESTRICT, and this only sets is_deleted).
create or replace function appointment.soft_delete_visit_type(p_visit_type_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row record;
begin
  select vt.id, vt.tenant_id, vt.is_deleted into v_row
  from appointment.visit_types vt where vt.id = p_visit_type_id for update;
  if v_row.id is null or v_row.tenant_id not in (select identity.current_tenant_ids()) or v_row.is_deleted then
    raise exception 'visit type not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_row.tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can delete visit types' using errcode = '42501';
  end if;
  update appointment.visit_types set is_deleted = true, is_active = false where id = v_row.id;
end;
$$;
revoke all on function appointment.soft_delete_visit_type(uuid) from public, anon;
grant execute on function appointment.soft_delete_visit_type(uuid) to authenticated, service_role, hms_svc_scheduling;
comment on function appointment.soft_delete_visit_type(uuid) is
  'Soft-deletes a visit type. Existing appointments keep visit_type_id and the fee and follow-up snapshots.';
