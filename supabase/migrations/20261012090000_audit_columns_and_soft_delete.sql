-- =============================================================================
-- Audit-column convention v2 + uniform soft delete (AUDIT-TZ-PLAN.md §A, approved 2026-10-09).
--
-- Every business table in identity / patient / appointment now carries
--   created_on timestamptz NOT NULL DEFAULT now(), created_by uuid NOT NULL,
--   updated_on timestamptz NOT NULL DEFAULT now(), updated_by uuid NOT NULL,
--   is_deleted boolean NOT NULL DEFAULT false
-- Exempt (decision E2): audit.audit_log (immutable, own changed_at/changed_by) and messaging.outbox.
--
--  1. EXPAND-then-contract (DB review B3): created_on/updated_on are ADDED next to the existing
--     created_at/updated_at and back-filled from them. The shared trigger keeps the legacy pair equal
--     to the new pair on every write, so readers of either name stay correct while services deploy
--     independently. A later migration drops created_at/updated_at once every reader has moved.
--     audit_log JSON rows carry both keys meanwhile; consumers must read either.
--  2. queue_counters gets the audit columns; every table gets is_deleted.
--  3. Existing rows: missing actors are back-filled with the fixed system actor
--     audit.system_actor() = 00000000-0000-4000-8000-00000000005e ("MediCore System", decision E4,
--     no FK). The back-fill runs with user triggers disabled, so updated_on is not bumped and no
--     audit_log rows are written. created_on/updated_on are back-filled from created_at/updated_at.
--  4. audit.stamp_audit_columns() is rewritten: the actor is auth.uid(), else the
--     transaction-local setting hms.actor_id (system jobs), else the system actor. Client-supplied
--     values for the five columns are ALWAYS overwritten (closes the created_by forgery gap: the
--     old trigger kept a client-sent created_by). is_deleted may only change inside the SECURITY
--     DEFINER soft-delete/restore functions (current_user is then the owner, not a client role).
--  5. Client INSERT/UPDATE privileges on the five columns are revoked (table-level grants on
--     branches/memberships become column-level grants).
--  6. Hard DELETE of branches, memberships, practitioners and schedules is replaced by soft delete
--     (decision E7): DELETE policies + grants dropped; <schema>.soft_delete_<x>() / restore_<x>()
--     functions added (tenant_admin only; 404-not-403 semantics like the patient functions).
--  7. Unique keys that a deleted row must not block become partial (WHERE NOT is_deleted).
--  8. RLS helpers and identity functions ignore deleted memberships / branches / tenants, so a
--     soft-deleted membership grants nothing. Non-admin SELECT policies hide deleted rows.
--  9. identity.user_profiles gets the row audit log (decision E6); audit_log.tenant_id becomes
--     nullable for global (non-tenant) rows, which only service_role can read.
-- 10. patients keeps deleted_at / deleted_by / deletion_reason; patients.is_deleted is a STORED
--     GENERATED column (deleted_at is not null), so the two can never drift (review S5). Patient
--     policies, functions and partial indexes use the single predicate NOT is_deleted.
--     patients_tenant_mrn_key stays a FULL unique key: an MRN is never reused.
-- 11. Status-lifecycle tables (appointments, queue_entries, queue_counters, tenants) carry
--     is_deleted for the convention only: CHECK (not is_deleted) (review S4).
-- 12. Cross-schema reads go through published, SECURITY DEFINER *_v1 functions (review B2):
--     appointment.branch_has_open_activity_v1 / queue_has_entries_v1 / patient_has_active_visits_v1,
--     identity.branch_exists_v1 / branch_tenant_id_v1, patient.patient_exists_v1.
-- 13. is_deleted guard fails CLOSED (review S3): only the table owner (the SECURITY DEFINER
--     soft-delete functions) or a writer that set the transaction-local flag hms.soft_delete to the
--     row id may change it; client roles never.
-- =============================================================================

-- ------------------------------------------------------------ system actor ----
create or replace function audit.system_actor()
returns uuid
language sql
immutable
set search_path = ''
as $$ select '00000000-0000-4000-8000-00000000005e'::uuid $$;
comment on function audit.system_actor() is
  'Fixed actor ("MediCore System") for rows written without a signed-in user (migrations, seed, jobs). No FK by design.';
revoke all on function audit.system_actor() from public;
grant execute on function audit.system_actor() to authenticated, service_role;

-- ------------------------------------------------- expand: created_on / updated_on ----
-- created_at / updated_at stay (deprecated, kept equal by audit.stamp_audit_columns('legacy_at')).
alter table identity.tenants          add column created_on timestamptz, add column updated_on timestamptz;
alter table identity.branches         add column created_on timestamptz, add column updated_on timestamptz;
alter table identity.user_profiles    add column created_on timestamptz, add column updated_on timestamptz;
alter table identity.memberships      add column created_on timestamptz, add column updated_on timestamptz;
alter table patient.patients          add column created_on timestamptz, add column updated_on timestamptz;
alter table appointment.practitioners add column created_on timestamptz, add column updated_on timestamptz;
alter table appointment.schedules     add column created_on timestamptz, add column updated_on timestamptz;
alter table appointment.appointments  add column created_on timestamptz, add column updated_on timestamptz;
alter table appointment.queue_entries add column created_on timestamptz, add column updated_on timestamptz;

-- --------------------------------------------------------------- new columns ----
alter table appointment.queue_counters
  add column created_on timestamptz not null default now(),
  add column created_by uuid,
  add column updated_on timestamptz not null default now(),
  add column updated_by uuid;

alter table identity.tenants          add column is_deleted boolean not null default false;
alter table identity.branches         add column is_deleted boolean not null default false;
alter table identity.user_profiles    add column is_deleted boolean not null default false;
alter table identity.memberships      add column is_deleted boolean not null default false;
-- generated: one source of truth with deleted_at (review S5)
alter table patient.patients          add column is_deleted boolean not null generated always as (deleted_at is not null) stored;
alter table appointment.practitioners add column is_deleted boolean not null default false;
alter table appointment.schedules     add column is_deleted boolean not null default false;
alter table appointment.appointments  add column is_deleted boolean not null default false;
alter table appointment.queue_entries add column is_deleted boolean not null default false;
alter table appointment.queue_counters add column is_deleted boolean not null default false;

-- ---------------------------------------------------------------- back-fill ----
do $$
declare
  t text;
begin
  foreach t in array array[
    'identity.tenants', 'identity.branches', 'identity.user_profiles', 'identity.memberships',
    'patient.patients', 'appointment.practitioners', 'appointment.schedules',
    'appointment.appointments', 'appointment.queue_entries', 'appointment.queue_counters']
  loop
    execute format('alter table %s disable trigger user', t);
    if t <> 'appointment.queue_counters' then
      execute format('update %s set created_on = created_at, updated_on = updated_at', t);
    end if;
    execute format(
      'update %s set created_by = coalesce(created_by, audit.system_actor()),
                     updated_by = coalesce(updated_by, created_by, audit.system_actor())
        where created_by is null or updated_by is null', t);
    execute format('alter table %s enable trigger user', t);
    execute format('alter table %s alter column created_by set not null, alter column updated_by set not null,
                    alter column created_on set not null, alter column updated_on set not null,
                    alter column created_on set default now(), alter column updated_on set default now()', t);
    if t <> 'appointment.queue_counters' then
      execute format('comment on column %s.created_at is %L', t,
        'DEPRECATED (expand/contract): mirror of created_on kept by audit.stamp_audit_columns; dropped once every reader uses created_on.');
      execute format('comment on column %s.updated_at is %L', t,
        'DEPRECATED (expand/contract): mirror of updated_on kept by audit.stamp_audit_columns; dropped once every reader uses updated_on.');
    end if;
  end loop;
end;
$$;

-- status-lifecycle tables: is_deleted exists for the convention only (review S4); cancel / status
-- is the lifecycle, so the overlap / one-active constraints never meet a "deleted" row.
alter table appointment.appointments   add constraint appointments_never_deleted   check (not is_deleted);
alter table appointment.queue_entries  add constraint queue_entries_never_deleted  check (not is_deleted);
alter table appointment.queue_counters add constraint queue_counters_never_deleted check (not is_deleted);
alter table identity.tenants           add constraint tenants_never_deleted        check (not is_deleted);

-- ---------------------------------------------------------- shared trigger ----
create or replace function audit.stamp_audit_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
-- Trigger arguments:
--   'legacy_at'            table still has created_at/updated_at (expand phase): keep them equal
--   'generated_is_deleted' is_deleted is a generated column (patients): never assign or guard it
declare
  v_actor uuid := coalesce(
    auth.uid(),
    nullif(current_setting('hms.actor_id', true), '')::uuid,
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
    -- is_deleted fails CLOSED (review S3): client roles never; any other role only as the table
    -- owner (the SECURITY DEFINER soft-delete/restore functions) or with the transaction-local
    -- flag hms.soft_delete set to this row's id by such a function.
    if not v_generated and new.is_deleted is distinct from old.is_deleted then
      select pg_catalog.pg_get_userbyid(c.relowner) into v_owner from pg_catalog.pg_class c where c.oid = tg_relid;
      if current_user in ('authenticated', 'anon')
         or (current_user <> v_owner
             and coalesce(current_setting('hms.soft_delete', true), '') is distinct from (pg_catalog.to_jsonb(new) ->> 'id')) then
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

create trigger queue_counters_audit_columns before insert or update on appointment.queue_counters
  for each row execute function audit.stamp_audit_columns();

-- existing stamp triggers get their arguments (expand phase: legacy created_at/updated_at mirror)
drop trigger tenants_audit_columns on identity.tenants;
create trigger tenants_audit_columns before insert or update on identity.tenants
  for each row execute function audit.stamp_audit_columns('legacy_at');
drop trigger branches_audit_columns on identity.branches;
create trigger branches_audit_columns before insert or update on identity.branches
  for each row execute function audit.stamp_audit_columns('legacy_at');
drop trigger user_profiles_audit_columns on identity.user_profiles;
create trigger user_profiles_audit_columns before insert or update on identity.user_profiles
  for each row execute function audit.stamp_audit_columns('legacy_at');
drop trigger memberships_audit_columns on identity.memberships;
create trigger memberships_audit_columns before insert or update on identity.memberships
  for each row execute function audit.stamp_audit_columns('legacy_at');
drop trigger patients_audit_columns on patient.patients;
create trigger patients_audit_columns before insert or update on patient.patients
  for each row execute function audit.stamp_audit_columns('legacy_at', 'generated_is_deleted');
drop trigger practitioners_audit_columns on appointment.practitioners;
create trigger practitioners_audit_columns before insert or update on appointment.practitioners
  for each row execute function audit.stamp_audit_columns('legacy_at');
drop trigger schedules_audit_columns on appointment.schedules;
create trigger schedules_audit_columns before insert or update on appointment.schedules
  for each row execute function audit.stamp_audit_columns('legacy_at');
drop trigger appointments_audit_columns on appointment.appointments;
create trigger appointments_audit_columns before insert or update on appointment.appointments
  for each row execute function audit.stamp_audit_columns('legacy_at');
drop trigger queue_entries_audit_columns on appointment.queue_entries;
create trigger queue_entries_audit_columns before insert or update on appointment.queue_entries
  for each row execute function audit.stamp_audit_columns('legacy_at');

-- --------------------------------------------- audit log on user_profiles ----
alter table audit.audit_log alter column tenant_id drop not null;
comment on column audit.audit_log.tenant_id is
  'Owning tenant. NULL for global rows (identity.user_profiles, identity.platform_admins): readable by service_role only.';
create trigger user_profiles_audit_log after insert or update or delete on identity.user_profiles
  for each row execute function audit.log_row_change();

-- -------------------------------------------------------------- client grants ----
revoke insert, update on identity.branches from authenticated;
grant insert (id, tenant_id, code, name, timezone, is_active) on identity.branches to authenticated;
grant update (name, timezone, is_active) on identity.branches to authenticated;

revoke insert, update on identity.memberships from authenticated;
grant insert (id, tenant_id, user_id, branch_id, role, status) on identity.memberships to authenticated;
grant update (branch_id, role, status) on identity.memberships to authenticated;

revoke insert (created_on, created_by, updated_on, updated_by, created_at, updated_at, deleted_at) on patient.patients from authenticated;
revoke update (created_on, updated_on, updated_by, created_at, updated_at) on patient.patients from authenticated;

-- ------------------------------------------- patients: one predicate (review S5) ----
drop index patient.patients_tenant_name_idx;
create index patients_tenant_name_idx on patient.patients (tenant_id, lower(last_name), lower(first_name)) where not is_deleted;
drop index patient.patients_tenant_phone_norm_idx;
create index patients_tenant_phone_norm_idx on patient.patients (tenant_id, patient.normalize_phone(phone)) where not is_deleted;
drop index patient.patients_tenant_dob_idx;
create index patients_tenant_dob_idx on patient.patients (tenant_id, date_of_birth) where not is_deleted;
drop index patient.patients_tenant_name_dob_idx;
create index patients_tenant_name_dob_idx
  on patient.patients (tenant_id, lower(btrim(last_name)), lower(btrim(first_name)), date_of_birth) where not is_deleted;

drop policy patients_select_registry_roles on patient.patients;
create policy patients_select_registry_roles on patient.patients
  for select to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing'])
         and (not is_deleted or identity.has_tenant_role(tenant_id, array['tenant_admin'])));
drop policy patients_update_registry_writers on patient.patients;
create policy patients_update_registry_writers on patient.patients
  for update to authenticated
  using (not is_deleted
         and identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
         and identity.can_access_branch(tenant_id, registered_branch_id))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
              and identity.can_access_branch(tenant_id, registered_branch_id));

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
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
begin
  -- 404-not-403: a tenant the caller is not a member of -> P0002; member without registry read -> 42501
  if p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(p_tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing']) then
    raise exception 'not permitted to search patients' using errcode = '42501';
  end if;

  return query
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
    and not p.is_deleted
    and (p_exclude_id is null or p.id <> p_exclude_id)
    and (m.by_name or m.by_phone)
  order by (m.by_name and m.by_phone) desc, p.last_name, p.first_name, p.mrn
  limit 20;
end;
$$;

-- hard delete -> soft delete
drop policy branches_delete_admin on identity.branches;
drop policy memberships_delete_admin on identity.memberships;
drop policy practitioners_delete_admin on appointment.practitioners;
drop policy schedules_delete_admin on appointment.schedules;
revoke delete on identity.branches, identity.memberships, appointment.practitioners, appointment.schedules from authenticated;

-- ------------------------------------------------------- partial unique keys ----
alter table identity.branches drop constraint branches_tenant_code_key;
create unique index branches_tenant_code_key on identity.branches (tenant_id, code) where not is_deleted;

alter table identity.memberships drop constraint memberships_tenant_user_branch_key;
create unique index memberships_tenant_user_branch_key
  on identity.memberships (tenant_id, user_id, branch_id) nulls not distinct where not is_deleted;

drop index appointment.practitioners_tenant_user_key;
create unique index practitioners_tenant_user_key
  on appointment.practitioners (tenant_id, user_id) where user_id is not null and not is_deleted;

alter table appointment.schedules drop constraint schedules_no_overlap;
alter table appointment.schedules add constraint schedules_no_overlap exclude using gist (
    tenant_id with =,
    practitioner_id with =,
    weekday with =,
    appointment.timerange(start_time, end_time) with &&,
    daterange(valid_from, coalesce(valid_to, 'infinity'::date), '[]') with &&
  ) where (is_active and not is_deleted);

-- ------------------------------------------------------------ RLS policies ----
drop policy branches_select_member on identity.branches;
create policy branches_select_member on identity.branches
  for select to authenticated
  using (tenant_id in (select identity.current_tenant_ids())
         and (not is_deleted or identity.has_tenant_role(tenant_id, array['tenant_admin'])));

drop policy branches_update_admin on identity.branches;
create policy branches_update_admin on identity.branches
  for update to authenticated
  using (not is_deleted and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));

drop policy memberships_select_own_or_admin on identity.memberships;
create policy memberships_select_own_or_admin on identity.memberships
  for select to authenticated
  using (
    (user_id = (select auth.uid()) and not is_deleted and tenant_id in (select identity.current_tenant_ids()))
    or (status <> 'invited' and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  );

drop policy memberships_update_admin on identity.memberships;
create policy memberships_update_admin on identity.memberships
  for update to authenticated
  using (not is_deleted and status <> 'invited' and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (status <> 'invited' and identity.has_tenant_role(tenant_id, array['tenant_admin']));

drop policy practitioners_select_member on appointment.practitioners;
create policy practitioners_select_member on appointment.practitioners
  for select to authenticated
  using (tenant_id in (select identity.current_tenant_ids())
         and (not is_deleted or identity.has_tenant_role(tenant_id, array['tenant_admin'])));

drop policy practitioners_update_admin on appointment.practitioners;
create policy practitioners_update_admin on appointment.practitioners
  for update to authenticated
  using (not is_deleted and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));

drop policy schedules_select_member on appointment.schedules;
create policy schedules_select_member on appointment.schedules
  for select to authenticated
  using (tenant_id in (select identity.current_tenant_ids())
         and (not is_deleted or identity.has_tenant_role(tenant_id, array['tenant_admin'])));

drop policy schedules_update_admin on appointment.schedules;
create policy schedules_update_admin on appointment.schedules
  for update to authenticated
  using (not is_deleted and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']) and identity.can_access_branch(tenant_id, branch_id));

-- ------------------------------------------- RLS helpers ignore deleted rows ----
create or replace function identity.current_tenant_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct m.tenant_id
  from identity.memberships m
  join identity.tenants t on t.id = m.tenant_id
  where m.user_id = auth.uid()
    and m.status = 'active'
    and not m.is_deleted
    and t.status = 'active'
    and not t.is_deleted
    and (identity.active_tenant_claim() is null or m.tenant_id = identity.active_tenant_claim())
$$;

create or replace function identity.has_tenant_role(p_tenant_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from identity.memberships m
    join identity.tenants t on t.id = m.tenant_id
    where m.user_id = auth.uid()
      and m.tenant_id = p_tenant_id
      and m.status = 'active'
      and not m.is_deleted
      and t.status = 'active'
      and not t.is_deleted
      and m.role = any (p_roles)
      and (identity.active_tenant_claim() is null or m.tenant_id = identity.active_tenant_claim())
  )
$$;

create or replace function identity.current_branch_ids(p_tenant_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select b.id
  from identity.branches b
  where b.tenant_id = p_tenant_id
    and not b.is_deleted
    and b.tenant_id in (select identity.current_tenant_ids())
    and exists (
      select 1 from identity.memberships m
      where m.user_id = auth.uid()
        and m.tenant_id = p_tenant_id
        and m.status = 'active'
        and not m.is_deleted
        and (m.branch_id is null or m.branch_id = b.id)
    )
$$;

create or replace function identity.shares_tenant_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from identity.memberships m
    where m.user_id = p_user_id
      and m.status = 'active'
      and not m.is_deleted
      and m.tenant_id in (select identity.current_tenant_ids())
  )
$$;

create or replace function identity.is_admin_of_member(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from identity.memberships m
    where m.user_id = p_user_id
      and m.status <> 'invited'
      and not m.is_deleted
      and identity.has_tenant_role(m.tenant_id, array['tenant_admin'])
  )
$$;

create or replace function identity.my_memberships()
returns table (tenant_id uuid, tenant_name text, branch_id uuid, branch_name text, role text)
language sql
stable
security definer
set search_path = ''
as $$
  select m.tenant_id, t.name, m.branch_id, b.name, m.role
  from identity.memberships m
  join identity.tenants t on t.id = m.tenant_id
  left join identity.branches b on b.id = m.branch_id
  where m.user_id = auth.uid() and m.status = 'active' and not m.is_deleted
    and t.status = 'active' and not t.is_deleted
    and (b.id is null or not b.is_deleted)
  order by t.name, b.name nulls first, m.role
$$;

create or replace function identity.my_invitations()
returns table (membership_id uuid, tenant_id uuid, tenant_name text, branch_id uuid, role text, invited_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select m.id, m.tenant_id, t.name, m.branch_id, m.role, m.created_on
  from identity.memberships m
  join identity.tenants t on t.id = m.tenant_id
  where m.user_id = auth.uid()
    and m.status = 'invited'
    and not m.is_deleted
    and t.status = 'active'
    and not t.is_deleted
  order by m.created_on, m.id
$$;

create or replace function identity.accept_membership(p_membership_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or p_membership_id is null then
    raise exception 'invitation not found' using errcode = 'P0002';
  end if;

  perform set_config('identity.accepting_membership', p_membership_id::text, true);

  update identity.memberships m
     set status = 'active'
   where m.id = p_membership_id
     and m.user_id = v_uid
     and m.status = 'invited'
     and not m.is_deleted
     and exists (select 1 from identity.tenants t where t.id = m.tenant_id and t.status = 'active' and not t.is_deleted);

  if not found then
    perform set_config('identity.accepting_membership', '', true);
    raise exception 'invitation not found' using errcode = 'P0002';
  end if;

  perform set_config('identity.accepting_membership', '', true);
end;
$$;

create or replace function identity.add_member(p_tenant_id uuid, p_email text, p_role text, p_branch_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_email text;
  v_id uuid;
begin
  if not identity.has_tenant_role(p_tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can add members' using errcode = '42501';
  end if;

  if p_branch_id is not null and not exists (
       select 1 from identity.branches b where b.tenant_id = p_tenant_id and b.id = p_branch_id and not b.is_deleted) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;

  select u.id, u.email into v_user, v_email
  from auth.users u
  where lower(u.email) = lower(btrim(p_email))
  order by u.id
  limit 1;
  if v_user is null then
    return null; -- no account: same outcome to the caller as an invite (no enumeration)
  end if;

  -- Same live (tenant, user, branch) already exists (any status, any role): return it unchanged.
  select m.id into v_id
  from identity.memberships m
  where m.tenant_id = p_tenant_id
    and m.user_id = v_user
    and m.branch_id is not distinct from p_branch_id
    and not m.is_deleted;
  if v_id is not null then
    return v_id;
  end if;

  insert into identity.user_profiles (id, email) values (v_user, v_email)
  on conflict (id) do nothing;

  insert into identity.memberships (tenant_id, user_id, branch_id, role, status)
  values (p_tenant_id, v_user, p_branch_id, p_role, 'invited')
  on conflict (tenant_id, user_id, branch_id) where not is_deleted do nothing
  returning id into v_id;

  if v_id is null then -- lost a race with a concurrent identical invite
    select m.id into v_id
    from identity.memberships m
    where m.tenant_id = p_tenant_id
      and m.user_id = v_user
      and m.branch_id is not distinct from p_branch_id
      and not m.is_deleted;
  end if;

  return v_id;
end;
$$;

create or replace function identity.set_active_context(p_tenant_id uuid, p_branch_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from identity.memberships m
    join identity.tenants t on t.id = m.tenant_id
    where m.user_id = v_uid and m.tenant_id = p_tenant_id and m.status = 'active' and not m.is_deleted
      and t.status = 'active' and not t.is_deleted
      and (p_branch_id is null or m.branch_id is null or m.branch_id = p_branch_id)
  ) then
    raise exception 'no active membership for the requested tenant/branch' using errcode = '42501';
  end if;

  if p_branch_id is not null and not exists (
    select 1 from identity.branches b
    where b.id = p_branch_id and b.tenant_id = p_tenant_id and b.is_active and not b.is_deleted
  ) then
    raise exception 'branch does not belong to tenant' using errcode = '42501';
  end if;

  insert into identity.user_profiles (id, email, active_tenant_id, active_branch_id)
  select u.id, u.email, p_tenant_id, p_branch_id from auth.users u where u.id = v_uid
  on conflict (id) do update
    set active_tenant_id = excluded.active_tenant_id,
        active_branch_id = excluded.active_branch_id;
end;
$$;

create or replace function identity.resolve_active_context(p_user_id uuid)
returns table (tenant_id uuid, branch_id uuid, branch_ids uuid[], roles text[])
language plpgsql
set search_path = ''
as $$
declare
  v_pref_tenant uuid;
  v_pref_branch uuid;
  v_tenant uuid;
  v_branch uuid;
  v_all_branches boolean;
  v_branch_ids uuid[];
  v_roles text[];
begin
  if p_user_id is null then
    return;
  end if;

  select p.active_tenant_id, p.active_branch_id into v_pref_tenant, v_pref_branch
  from identity.user_profiles p where p.id = p_user_id;

  select m.tenant_id into v_tenant
  from identity.memberships m
  join identity.tenants t on t.id = m.tenant_id
  where m.user_id = p_user_id and m.status = 'active' and not m.is_deleted
    and t.status = 'active' and not t.is_deleted
  order by (m.tenant_id = v_pref_tenant) desc nulls last, m.created_on, m.tenant_id
  limit 1;

  if v_tenant is null then
    return;
  end if;

  if v_pref_tenant is null then
    begin
      insert into identity.user_profiles (id, email, active_tenant_id, active_branch_id)
      select u.id, u.email, v_tenant, null from auth.users u where u.id = p_user_id
      on conflict (id) do update
        set active_tenant_id = excluded.active_tenant_id,
            active_branch_id = null
        where identity.user_profiles.active_tenant_id is null;
    exception when others then
      raise warning 'resolve_active_context: could not persist default tenant: %', sqlerrm;
    end;
  end if;

  select bool_or(m.branch_id is null) into v_all_branches
  from identity.memberships m
  where m.user_id = p_user_id and m.tenant_id = v_tenant and m.status = 'active' and not m.is_deleted;

  select coalesce(array_agg(b.id order by b.name, b.id), '{}') into v_branch_ids
  from identity.branches b
  where b.tenant_id = v_tenant
    and b.is_active
    and not b.is_deleted
    and (v_all_branches or exists (
      select 1 from identity.memberships m
      where m.user_id = p_user_id and m.tenant_id = v_tenant and m.status = 'active' and not m.is_deleted
        and m.branch_id = b.id));

  if v_tenant = v_pref_tenant and v_pref_branch = any (v_branch_ids) then
    v_branch := v_pref_branch;
  end if;

  select coalesce(array_agg(distinct m.role order by m.role), '{}') into v_roles
  from identity.memberships m
  where m.user_id = p_user_id and m.tenant_id = v_tenant and m.status = 'active' and not m.is_deleted
    and (v_branch is null or m.branch_id is null or m.branch_id = v_branch);

  tenant_id := v_tenant;
  branch_id := v_branch;
  branch_ids := v_branch_ids;
  roles := v_roles;
  return next;
end;
$$;

-- =========================================== published cross-schema surface (v1) ====
-- cross-schema: approved (DB review B2). Other schemas call ONLY these, never the tables.
-- Each is SECURITY DEFINER with an explicit tenant check: whenever a signed-in user is behind the
-- call (auth.uid() set, also when reached through another SECURITY DEFINER function, where
-- current_user is the owner) they must be a member of p_tenant_id, else P0002 (404-not-403).
-- Trusted callers without a user (service_role jobs, system triggers) skip the membership check.

-- scheduling -> published for identity (branch soft delete) -------------------------------
create or replace function appointment.branch_has_open_activity_v1(p_tenant_id uuid, p_branch_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return exists (select 1 from appointment.appointments a
                 where a.tenant_id = p_tenant_id and a.branch_id = p_branch_id
                   and a.status in ('booked', 'checked_in', 'in_consultation'))
      or exists (select 1 from appointment.queue_entries q
                 where q.tenant_id = p_tenant_id and q.branch_id = p_branch_id
                   and q.status in ('waiting', 'in_consultation'));
end;
$$;
comment on function appointment.branch_has_open_activity_v1(uuid, uuid) is
  'v1 (published by scheduling): true when the branch has open appointments or active queue entries.';

-- scheduling -> published for identity (time-zone change lock) ----------------------------
create or replace function appointment.queue_has_entries_v1(p_tenant_id uuid, p_branch_ids uuid[], p_days date[])
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return exists (select 1 from appointment.queue_entries q
                 where q.tenant_id = p_tenant_id and q.branch_id = any (p_branch_ids)
                   and q.queue_date = any (p_days));
end;
$$;
comment on function appointment.queue_has_entries_v1(uuid, uuid[], date[]) is
  'v1 (published by scheduling): true when any of the branches has queue entries on any of the days.';

-- scheduling -> published for patients (patient soft delete) -----------------------------
create or replace function appointment.patient_has_active_visits_v1(p_tenant_id uuid, p_patient_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return exists (select 1 from appointment.appointments a
                 where a.tenant_id = p_tenant_id and a.patient_id = p_patient_id
                   and a.status in ('booked', 'checked_in', 'in_consultation'))
      or exists (select 1 from appointment.queue_entries q
                 where q.tenant_id = p_tenant_id and q.patient_id = p_patient_id
                   and q.status in ('waiting', 'in_consultation'));
end;
$$;
comment on function appointment.patient_has_active_visits_v1(uuid, uuid) is
  'v1 (published by scheduling): true when the patient has open appointments or active queue entries.';

-- identity -> published for scheduling -----------------------------------------------------
create or replace function identity.branch_exists_v1(p_tenant_id uuid, p_branch_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return exists (select 1 from identity.branches b
                 where b.tenant_id = p_tenant_id and b.id = p_branch_id and not b.is_deleted);
end;
$$;
comment on function identity.branch_exists_v1(uuid, uuid) is
  'v1 (published by identity): the branch exists in the tenant and is not soft-deleted.';

create or replace function identity.branch_tenant_id_v1(p_branch_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  select b.tenant_id into v_tenant from identity.branches b where b.id = p_branch_id and not b.is_deleted;
  if auth.uid() is not null
     and (v_tenant is null or v_tenant not in (select identity.current_tenant_ids())) then
    return null;  -- unknown and foreign look the same
  end if;
  return v_tenant;
end;
$$;
comment on function identity.branch_tenant_id_v1(uuid) is
  'v1 (published by identity): tenant of a live branch, NULL when unknown, deleted or (for clients) foreign.';

-- patients -> published for scheduling -----------------------------------------------------
create or replace function patient.patient_exists_v1(p_tenant_id uuid, p_patient_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return exists (select 1 from patient.patients p
                 where p.tenant_id = p_tenant_id and p.id = p_patient_id and not p.is_deleted);
end;
$$;
comment on function patient.patient_exists_v1(uuid, uuid) is
  'v1 (published by patients): the patient exists in the tenant and is not soft-deleted.';

revoke all on function appointment.branch_has_open_activity_v1(uuid, uuid) from public, anon;
revoke all on function appointment.queue_has_entries_v1(uuid, uuid[], date[]) from public, anon;
revoke all on function appointment.patient_has_active_visits_v1(uuid, uuid) from public, anon;
revoke all on function identity.branch_exists_v1(uuid, uuid) from public, anon;
revoke all on function identity.branch_tenant_id_v1(uuid) from public, anon;
revoke all on function patient.patient_exists_v1(uuid, uuid) from public, anon;
grant execute on function appointment.branch_has_open_activity_v1(uuid, uuid) to authenticated, service_role;
grant execute on function appointment.queue_has_entries_v1(uuid, uuid[], date[]) to authenticated, service_role;
grant execute on function appointment.patient_has_active_visits_v1(uuid, uuid) to authenticated, service_role;
grant execute on function identity.branch_exists_v1(uuid, uuid) to authenticated, service_role;
grant execute on function identity.branch_tenant_id_v1(uuid) to authenticated, service_role;
grant execute on function patient.patient_exists_v1(uuid, uuid) to authenticated, service_role;

-- -------------------------------- appointment helpers: deleted rows are unknown ----
create or replace function appointment.assert_tenant_refs(p_tenant_id uuid, p_branch_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if p_branch_id is not null and not identity.branch_exists_v1(p_tenant_id, p_branch_id) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
end;
$$;

create or replace function appointment.assert_practitioner_bookable(p_tenant_id uuid, p_practitioner_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active boolean;
begin
  select pr.is_active into v_active from appointment.practitioners pr
  where pr.tenant_id = p_tenant_id and pr.id = p_practitioner_id and not pr.is_deleted;
  if v_active is null then
    raise exception 'practitioner not found' using errcode = 'P0002';
  elsif not v_active then
    raise exception 'practitioner_inactive' using errcode = '23514';
  end if;
end;
$$;

create or replace function appointment.check_in_walk_in(p_branch_id uuid, p_patient_id uuid, p_practitioner_id uuid default null)
returns table (queue_entry_id uuid, token_no integer, queue_date date)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  v_tenant := identity.branch_tenant_id_v1(p_branch_id);
  if v_tenant is null or v_tenant not in (select identity.current_tenant_ids()) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;

  if not identity.has_tenant_role(v_tenant, array['tenant_admin', 'receptionist', 'nurse'])
     or not identity.can_access_branch(v_tenant, p_branch_id) then
    raise exception 'not permitted to check in at this branch' using errcode = '42501';
  end if;

  if not patient.patient_exists_v1(v_tenant, p_patient_id) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;

  if p_practitioner_id is not null and not exists (
       select 1 from appointment.practitioners pr
       where pr.tenant_id = v_tenant and pr.id = p_practitioner_id and pr.is_active and not pr.is_deleted) then
    raise exception 'practitioner not found' using errcode = 'P0002';
  end if;

  return query select * from appointment.issue_queue_token(v_tenant, p_branch_id, p_patient_id, null, p_practitioner_id);
end;
$$;

-- ------------------------------------------------------ patient soft delete ----
create or replace function patient.soft_delete_patient(p_patient_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p record;
begin
  if p_reason is not null and length(p_reason) > 500 then
    raise exception 'reason too long (max 500)' using errcode = '22023';
  end if;

  select p.id, p.tenant_id, p.registered_branch_id, p.is_deleted into v_p
  from patient.patients p where p.id = p_patient_id
  for update;

  if v_p.id is null or v_p.tenant_id not in (select identity.current_tenant_ids()) or v_p.is_deleted then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;

  if not identity.has_tenant_role(v_p.tenant_id, array['tenant_admin', 'receptionist'])
     or not identity.can_access_branch(v_p.tenant_id, v_p.registered_branch_id) then
    raise exception 'not permitted to delete this patient' using errcode = '42501';
  end if;

  if appointment.patient_has_active_visits_v1(v_p.tenant_id, v_p.id) then
    raise exception 'patient has open appointments or queue entries; cancel them first' using errcode = '55000';
  end if;

  -- is_deleted is generated from deleted_at
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
security definer
set search_path = ''
as $$
declare
  v_p record;
begin
  select p.id, p.tenant_id, p.is_deleted into v_p
  from patient.patients p where p.id = p_patient_id
  for update;

  if v_p.id is null or v_p.tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_p.tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can restore patients' using errcode = '42501';
  end if;
  if not v_p.is_deleted then
    raise exception 'patient is not deleted' using errcode = 'P0002';
  end if;

  update patient.patients
     set deleted_at = null, deleted_by = null, deletion_reason = null
   where id = v_p.id;
end;
$$;

-- -------------------------------------------- soft delete / restore (admin) ----
-- Shared contract: unknown id, another tenant's id, (delete) an already-deleted row or (restore) a
-- live row -> P0002 (404); same tenant without tenant_admin -> 42501 (403); business conflict -> 55000
-- (409); restoring into a taken unique key -> 23505 / 23P01 (409).

create or replace function identity.soft_delete_branch(p_branch_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b record;
begin
  select b.id, b.tenant_id, b.is_deleted into v_b from identity.branches b where b.id = p_branch_id for update;
  if v_b.id is null or v_b.tenant_id not in (select identity.current_tenant_ids()) or v_b.is_deleted then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_b.tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can delete branches' using errcode = '42501';
  end if;
  if not exists (select 1 from identity.branches b
                 where b.tenant_id = v_b.tenant_id and b.id <> v_b.id and not b.is_deleted) then
    raise exception 'a hospital needs at least one branch' using errcode = '55000';
  end if;
  if appointment.branch_has_open_activity_v1(v_b.tenant_id, v_b.id) then
    raise exception 'branch has open appointments or queue entries' using errcode = '55000';
  end if;
  perform set_config('hms.soft_delete', v_b.id::text, true);
  update identity.branches set is_deleted = true, is_active = false where id = v_b.id;
  perform set_config('hms.soft_delete', '', true);
end;
$$;

create or replace function identity.restore_branch(p_branch_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b record;
begin
  select b.id, b.tenant_id, b.is_deleted into v_b from identity.branches b where b.id = p_branch_id for update;
  if v_b.id is null or v_b.tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_b.tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can restore branches' using errcode = '42501';
  end if;
  if not v_b.is_deleted then
    raise exception 'branch is not deleted' using errcode = 'P0002';
  end if;
  -- comes back inactive: the admin re-activates it explicitly
  perform set_config('hms.soft_delete', v_b.id::text, true);
  update identity.branches set is_deleted = false where id = v_b.id;
  perform set_config('hms.soft_delete', '', true);
end;
$$;

create or replace function identity.soft_delete_membership(p_membership_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m record;
begin
  select m.id, m.tenant_id, m.user_id, m.status, m.is_deleted into v_m
  from identity.memberships m where m.id = p_membership_id for update;
  -- invitations are invisible to admins (no account enumeration): treated as not found
  if v_m.id is null or v_m.tenant_id not in (select identity.current_tenant_ids())
     or v_m.is_deleted or v_m.status = 'invited' then
    raise exception 'membership not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_m.tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can remove members' using errcode = '42501';
  end if;
  if v_m.user_id = auth.uid() then
    raise exception 'you cannot remove your own membership' using errcode = '55000';
  end if;
  perform set_config('hms.soft_delete', v_m.id::text, true);
  update identity.memberships set is_deleted = true where id = v_m.id;
  perform set_config('hms.soft_delete', '', true);
end;
$$;

create or replace function identity.restore_membership(p_membership_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m record;
begin
  select m.id, m.tenant_id, m.status, m.is_deleted into v_m
  from identity.memberships m where m.id = p_membership_id for update;
  if v_m.id is null or v_m.tenant_id not in (select identity.current_tenant_ids()) or v_m.status = 'invited' then
    raise exception 'membership not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_m.tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can restore members' using errcode = '42501';
  end if;
  if not v_m.is_deleted then
    raise exception 'membership is not deleted' using errcode = 'P0002';
  end if;
  perform set_config('hms.soft_delete', v_m.id::text, true);
  update identity.memberships set is_deleted = false where id = v_m.id;
  perform set_config('hms.soft_delete', '', true);
end;
$$;

create or replace function appointment.soft_delete_practitioner(p_practitioner_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p record;
begin
  select pr.id, pr.tenant_id, pr.is_deleted into v_p
  from appointment.practitioners pr where pr.id = p_practitioner_id for update;
  if v_p.id is null or v_p.tenant_id not in (select identity.current_tenant_ids()) or v_p.is_deleted then
    raise exception 'practitioner not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_p.tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can delete practitioners' using errcode = '42501';
  end if;
  if exists (select 1 from appointment.appointments a
             where a.tenant_id = v_p.tenant_id and a.practitioner_id = v_p.id
               and a.status in ('booked', 'checked_in', 'in_consultation')) then
    raise exception 'practitioner has open appointments' using errcode = '55000';
  end if;
  perform set_config('hms.soft_delete', v_p.id::text, true);
  update appointment.practitioners set is_deleted = true, is_active = false where id = v_p.id;
  perform set_config('hms.soft_delete', '', true);
end;
$$;

create or replace function appointment.restore_practitioner(p_practitioner_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p record;
begin
  select pr.id, pr.tenant_id, pr.is_deleted into v_p
  from appointment.practitioners pr where pr.id = p_practitioner_id for update;
  if v_p.id is null or v_p.tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'practitioner not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_p.tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can restore practitioners' using errcode = '42501';
  end if;
  if not v_p.is_deleted then
    raise exception 'practitioner is not deleted' using errcode = 'P0002';
  end if;
  perform set_config('hms.soft_delete', v_p.id::text, true);
  update appointment.practitioners set is_deleted = false where id = v_p.id;
  perform set_config('hms.soft_delete', '', true);
end;
$$;

create or replace function appointment.soft_delete_schedule(p_schedule_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s record;
begin
  select s.id, s.tenant_id, s.branch_id, s.is_deleted into v_s
  from appointment.schedules s where s.id = p_schedule_id for update;
  if v_s.id is null or v_s.tenant_id not in (select identity.current_tenant_ids()) or v_s.is_deleted then
    raise exception 'schedule not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_s.tenant_id, array['tenant_admin'])
     or not identity.can_access_branch(v_s.tenant_id, v_s.branch_id) then
    raise exception 'only tenant admins can delete schedules' using errcode = '42501';
  end if;
  perform set_config('hms.soft_delete', v_s.id::text, true);
  update appointment.schedules set is_deleted = true where id = v_s.id;
  perform set_config('hms.soft_delete', '', true);
end;
$$;

create or replace function appointment.restore_schedule(p_schedule_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s record;
begin
  select s.id, s.tenant_id, s.branch_id, s.is_deleted into v_s
  from appointment.schedules s where s.id = p_schedule_id for update;
  if v_s.id is null or v_s.tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'schedule not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_s.tenant_id, array['tenant_admin'])
     or not identity.can_access_branch(v_s.tenant_id, v_s.branch_id) then
    raise exception 'only tenant admins can restore schedules' using errcode = '42501';
  end if;
  if not v_s.is_deleted then
    raise exception 'schedule is not deleted' using errcode = 'P0002';
  end if;
  perform set_config('hms.soft_delete', v_s.id::text, true);
  update appointment.schedules set is_deleted = false where id = v_s.id;
  perform set_config('hms.soft_delete', '', true);
end;
$$;

do $$
declare
  f text;
begin
  foreach f in array array[
    'identity.soft_delete_branch(uuid)', 'identity.restore_branch(uuid)',
    'identity.soft_delete_membership(uuid)', 'identity.restore_membership(uuid)',
    'appointment.soft_delete_practitioner(uuid)', 'appointment.restore_practitioner(uuid)',
    'appointment.soft_delete_schedule(uuid)', 'appointment.restore_schedule(uuid)']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end;
$$;

comment on column identity.branches.is_deleted is 'Soft delete (identity.soft_delete_branch / restore_branch). Never client-written.';
comment on column identity.memberships.is_deleted is 'Soft delete (identity.soft_delete_membership / restore_membership). A deleted membership grants nothing.';
comment on column appointment.practitioners.is_deleted is 'Soft delete (appointment.soft_delete_practitioner / restore_practitioner).';
comment on column appointment.schedules.is_deleted is 'Soft delete (appointment.soft_delete_schedule / restore_schedule).';
comment on column patient.patients.is_deleted is 'GENERATED (deleted_at is not null): the single soft-delete predicate for patients.';
