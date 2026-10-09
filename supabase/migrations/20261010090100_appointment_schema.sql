-- =============================================================================
-- Sprint 2 / Migration 12: appointment schema - practitioners, weekly schedules, computed
-- slots, appointments with a status machine and a no-double-booking exclusion constraint.
-- Contract: /workspace/SPRINT2-CONTRACT.md §2 (D4, D5, D9, D10).
-- Branch-role binding ("role X AT branch Y") is enforced in the API (D9); the DB enforces
-- role-in-tenant + branch access, like Sprint 1 patients.
-- =============================================================================

create schema if not exists extensions;
create extension if not exists btree_gist with schema extensions;

create schema if not exists appointment;
comment on schema appointment is 'Appointment service: practitioners, schedules, appointments, OPD queue (tenant-owned).';
revoke all on schema appointment from public;
grant usage on schema appointment to authenticated, service_role;

-- Range over time-of-day, used for schedule overlap.
do $$
begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where n.nspname = 'appointment' and t.typname = 'timerange') then
    create type appointment.timerange as range (subtype = time);
  end if;
end
$$;

-- ----------------------------------------------------------------- practitioners ----
create table appointment.practitioners (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references identity.tenants (id) on delete restrict,
  user_id       uuid references auth.users (id) on delete set null,
  display_name  text not null,
  specialty     text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  constraint practitioners_display_name_len check (length(btrim(display_name)) between 1 and 120),
  constraint practitioners_specialty_len check (specialty is null or length(specialty) <= 120),
  constraint practitioners_tenant_id_id_key unique (tenant_id, id)
);
create unique index practitioners_tenant_user_key on appointment.practitioners (tenant_id, user_id) where user_id is not null;

-- --------------------------------------------------------------------- schedules ----
create table appointment.schedules (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references identity.tenants (id) on delete restrict,
  practitioner_id  uuid not null,
  branch_id        uuid not null,
  weekday          smallint not null,
  start_time       time not null,
  end_time         time not null,
  slot_minutes     smallint not null default 15,
  valid_from       date not null default current_date,
  valid_to         date,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint schedules_practitioner_same_tenant
    foreign key (tenant_id, practitioner_id) references appointment.practitioners (tenant_id, id) on delete cascade,
  constraint schedules_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete cascade,
  constraint schedules_weekday_iso check (weekday between 1 and 7),
  constraint schedules_time_order check (start_time < end_time),
  constraint schedules_slot_minutes check (slot_minutes between 5 and 240),
  constraint schedules_validity check (valid_to is null or valid_to >= valid_from),
  constraint schedules_tenant_id_id_key unique (tenant_id, id),
  constraint schedules_no_overlap exclude using gist (
    tenant_id with =,
    practitioner_id with =,
    weekday with =,
    appointment.timerange(start_time, end_time) with &&,
    daterange(valid_from, coalesce(valid_to, 'infinity'::date), '[]') with &&
  ) where (is_active)
);
create index schedules_tenant_branch_idx on appointment.schedules (tenant_id, branch_id, weekday);
comment on table appointment.schedules is
  'Weekly working hours (ISO weekday 1=Mon..7=Sun) in branch-local wall-clock time (identity.branches.timezone).';

-- ------------------------------------------------------------------ appointments ----
create table appointment.appointments (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references identity.tenants (id) on delete restrict,
  branch_id        uuid not null,
  practitioner_id  uuid not null,
  patient_id       uuid not null,
  starts_at        timestamptz not null,
  ends_at          timestamptz not null,
  -- CASE keeps a reversed range from raising 22000 here, so appointments_time_order reports 23514 instead.
  during           tstzrange generated always as
                     (case when ends_at > starts_at then tstzrange(starts_at, ends_at, '[)') end) stored,
  status           text not null default 'booked',
  reason           text,
  cancel_reason    text,
  checked_in_at    timestamptz,
  started_at       timestamptz,
  completed_at     timestamptz,
  cancelled_at     timestamptz,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint appointments_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete restrict,
  constraint appointments_practitioner_same_tenant
    foreign key (tenant_id, practitioner_id) references appointment.practitioners (tenant_id, id) on delete restrict,
  constraint appointments_patient_same_tenant
    foreign key (tenant_id, patient_id) references patient.patients (tenant_id, id) on delete restrict,
  constraint appointments_time_valid check (ends_at > starts_at and ends_at - starts_at <= interval '8 hours'),
  constraint appointments_status_valid check (status in ('booked', 'checked_in', 'in_consultation', 'completed', 'cancelled', 'no_show')),
  constraint appointments_reason_len check (reason is null or length(reason) <= 500),
  constraint appointments_cancel_reason_len check (cancel_reason is null or length(cancel_reason) <= 500),
  constraint appointments_tenant_id_id_key unique (tenant_id, id),
  -- D5: no double booking per practitioner; cancelled / no_show free their time.
  constraint appointments_no_practitioner_overlap exclude using gist (
    tenant_id with =,
    practitioner_id with =,
    during with &&
  ) where (status in ('booked', 'checked_in', 'in_consultation', 'completed'))
);
create index appointments_tenant_branch_start_idx on appointment.appointments (tenant_id, branch_id, starts_at);
create index appointments_tenant_practitioner_start_idx on appointment.appointments (tenant_id, practitioner_id, starts_at);
create index appointments_tenant_patient_start_idx on appointment.appointments (tenant_id, patient_id, starts_at);

-- ------------------------------------------------------ status machine trigger ----
-- Practitioner must exist in the SAME tenant (else 23503) and be active (else 23514).
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
  where pr.tenant_id = p_tenant_id and pr.id = p_practitioner_id;
  if v_active is null then
    raise exception 'practitioner not found in this tenant' using errcode = '23503';
  elsif not v_active then
    raise exception 'practitioner_inactive' using errcode = '23514';
  end if;
end;
$$;
revoke all on function appointment.assert_practitioner_bookable(uuid, uuid) from public, anon, authenticated;

-- Transaction-local flags (bound to the row id) let the check-in / queue RPCs perform the
-- transitions reserved to them; same pattern as identity.accept_membership().
create or replace function appointment.enforce_appointment_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_via_checkin boolean;
  v_via_queue   boolean;
  v_ok          boolean;
begin
  if tg_op = 'INSERT' then
    if new.status is distinct from 'booked' then
      raise exception 'invalid_transition:new->%', new.status using errcode = '23514';
    end if;
    new.checked_in_at := null; new.started_at := null; new.completed_at := null; new.cancelled_at := null;
    if not exists (select 1 from patient.patients p
                   where p.tenant_id = new.tenant_id and p.id = new.patient_id and p.deleted_at is null) then
      raise exception 'patient not found or deleted' using errcode = '23503';
    end if;
    perform appointment.assert_practitioner_bookable(new.tenant_id, new.practitioner_id);
    return new;
  end if;

  -- UPDATE
  -- lifecycle timestamps are trigger-owned
  new.checked_in_at := old.checked_in_at; new.started_at := old.started_at;
  new.completed_at := old.completed_at;   new.cancelled_at := old.cancelled_at;

  if old.status <> 'booked' and (
       new.starts_at is distinct from old.starts_at or new.ends_at is distinct from old.ends_at
       or new.practitioner_id is distinct from old.practitioner_id or new.patient_id is distinct from old.patient_id
       or new.branch_id is distinct from old.branch_id) then
    raise exception 'invalid_transition:reschedule_not_booked' using errcode = '23514';
  end if;

  if new.practitioner_id is distinct from old.practitioner_id then
    perform appointment.assert_practitioner_bookable(new.tenant_id, new.practitioner_id);
  end if;

  if new.status is not distinct from old.status then
    return new;
  end if;

  v_via_checkin := coalesce(current_setting('appointment.check_in', true), '') = old.id::text;
  v_via_queue   := coalesce(current_setting('appointment.queue_sync', true), '') = old.id::text;

  v_ok := case
    when old.status = 'booked' and new.status = 'checked_in' then v_via_checkin
    when old.status = 'booked' and new.status = 'cancelled' then true
    when old.status = 'booked' and new.status = 'no_show' then now() >= old.starts_at
    when old.status = 'checked_in' and new.status in ('in_consultation', 'cancelled') then true
    when old.status = 'in_consultation' and new.status = 'completed' then true
    when old.status = 'in_consultation' and new.status = 'cancelled' then v_via_queue  -- queue entry cancelled mid-consult
    else false
  end;
  if not v_ok then
    raise exception 'invalid_transition:%->%', old.status, new.status using errcode = '23514';
  end if;

  -- clinical progress (in_consultation / completed) is for doctor / nurse / tenant_admin,
  -- or the queue RPC (which checks its own roles)
  if new.status in ('in_consultation', 'completed') and not v_via_queue and auth.uid() is not null
     and not identity.has_tenant_role(new.tenant_id, array['tenant_admin', 'doctor', 'nurse']) then
    raise exception 'not permitted to move an appointment to %', new.status using errcode = '42501';
  end if;

  case new.status
    when 'checked_in' then new.checked_in_at := now();
    when 'in_consultation' then new.started_at := now();
    when 'completed' then new.completed_at := now();
    when 'cancelled' then new.cancelled_at := now();
    else null;
  end case;
  return new;
end;
$$;
revoke all on function appointment.enforce_appointment_transition() from public;

create trigger appointments_status_machine before insert or update on appointment.appointments
  for each row execute function appointment.enforce_appointment_transition();

-- --------------------------------------------------- audit + tenant immutability ----
create trigger practitioners_audit_columns before insert or update on appointment.practitioners
  for each row execute function audit.stamp_audit_columns();
create trigger schedules_audit_columns before insert or update on appointment.schedules
  for each row execute function audit.stamp_audit_columns();
create trigger appointments_audit_columns before insert or update on appointment.appointments
  for each row execute function audit.stamp_audit_columns();
create trigger practitioners_tenant_immutable before update on appointment.practitioners
  for each row execute function audit.prevent_tenant_change();
create trigger schedules_tenant_immutable before update on appointment.schedules
  for each row execute function audit.prevent_tenant_change();
create trigger appointments_tenant_immutable before update on appointment.appointments
  for each row execute function audit.prevent_tenant_change();
create trigger practitioners_audit_log after insert or update or delete on appointment.practitioners
  for each row execute function audit.log_row_change();
create trigger schedules_audit_log after insert or update or delete on appointment.schedules
  for each row execute function audit.log_row_change();
create trigger appointments_audit_log after insert or update or delete on appointment.appointments
  for each row execute function audit.log_row_change();

-- --------------------------------------------------------------------- slots ----
-- SECURITY DEFINER (contract v3): busy times must reflect ALL bookings, also for callers who
-- cannot read appointments; it returns only practitioner ids and times (no PHI).
create or replace function appointment.available_slots(
  p_tenant_id uuid,
  p_branch_id uuid,
  p_from date,
  p_to date,
  p_practitioner_id uuid default null)
returns table (practitioner_id uuid, branch_id uuid, slot_start timestamptz, slot_end timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 31 then
    raise exception 'invalid date range (max 31 days)' using errcode = '22023';
  end if;
  if not identity.can_access_branch(p_tenant_id, p_branch_id) then
    raise exception 'not permitted for this branch' using errcode = '42501';
  end if;
  select b.timezone into v_tz from identity.branches b where b.id = p_branch_id and b.tenant_id = p_tenant_id;

  return query
  with days as (
    select d::date as day from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
  ), sch as (
    select s.practitioner_id, s.start_time, s.end_time, s.slot_minutes, days.day
    from appointment.schedules s
    join appointment.practitioners pr on pr.tenant_id = s.tenant_id and pr.id = s.practitioner_id and pr.is_active
    join days on extract(isodow from days.day) = s.weekday
             and days.day >= s.valid_from and (s.valid_to is null or days.day <= s.valid_to)
    where s.tenant_id = p_tenant_id and s.branch_id = p_branch_id and s.is_active
      and (p_practitioner_id is null or s.practitioner_id = p_practitioner_id)
  ), slots as (
    select sch.practitioner_id,
           ((sch.day + sch.start_time) + make_interval(mins => k * sch.slot_minutes)) at time zone v_tz as s_start,
           ((sch.day + sch.start_time) + make_interval(mins => (k + 1) * sch.slot_minutes)) at time zone v_tz as s_end
    from sch
    cross join lateral generate_series(
      0, (floor(extract(epoch from (sch.end_time - sch.start_time)) / 60 / sch.slot_minutes))::int - 1) k
  )
  select sl.practitioner_id, p_branch_id, sl.s_start, sl.s_end
  from slots sl
  where sl.s_start > now()
    and not exists (
      select 1 from appointment.appointments a
      where a.tenant_id = p_tenant_id and a.practitioner_id = sl.practitioner_id
        and a.status in ('booked', 'checked_in', 'in_consultation', 'completed')
        and a.during && tstzrange(sl.s_start, sl.s_end, '[)'))
  order by sl.s_start, sl.practitioner_id;
end;
$$;

-- ---------------------------------------------------------------------- RLS ----
alter table appointment.practitioners enable row level security;
alter table appointment.schedules     enable row level security;
alter table appointment.appointments  enable row level security;

create policy practitioners_select_member on appointment.practitioners
  for select to authenticated using (tenant_id in (select identity.current_tenant_ids()));
create policy practitioners_insert_admin on appointment.practitioners
  for insert to authenticated with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));
create policy practitioners_update_admin on appointment.practitioners
  for update to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']));
create policy practitioners_delete_admin on appointment.practitioners
  for delete to authenticated using (identity.has_tenant_role(tenant_id, array['tenant_admin']));

create policy schedules_select_member on appointment.schedules
  for select to authenticated using (tenant_id in (select identity.current_tenant_ids()));
create policy schedules_insert_admin on appointment.schedules
  for insert to authenticated
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']) and identity.can_access_branch(tenant_id, branch_id));
create policy schedules_update_admin on appointment.schedules
  for update to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin']) and identity.can_access_branch(tenant_id, branch_id));
create policy schedules_delete_admin on appointment.schedules
  for delete to authenticated using (identity.has_tenant_role(tenant_id, array['tenant_admin']));

create policy appointments_select_registry_roles on appointment.appointments
  for select to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing']));
create policy appointments_insert_writers on appointment.appointments
  for insert to authenticated
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
              and identity.can_access_branch(tenant_id, branch_id));
create policy appointments_update_writers on appointment.appointments
  for update to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
         and identity.can_access_branch(tenant_id, branch_id))
  with check (identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist'])
              and identity.can_access_branch(tenant_id, branch_id));
-- no DELETE policy: appointments are cancelled, never deleted

-- -------------------------------------------------------------------- grants ----
grant select on appointment.practitioners, appointment.schedules, appointment.appointments to authenticated;
grant insert (id, tenant_id, user_id, display_name, specialty, is_active) on appointment.practitioners to authenticated;
grant update (user_id, display_name, specialty, is_active) on appointment.practitioners to authenticated;
grant delete on appointment.practitioners to authenticated;
grant insert (id, tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from, valid_to, is_active)
  on appointment.schedules to authenticated;
grant update (practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from, valid_to, is_active)
  on appointment.schedules to authenticated;
grant delete on appointment.schedules to authenticated;
grant insert (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason)
  on appointment.appointments to authenticated;
grant update (starts_at, ends_at, practitioner_id, status, reason, cancel_reason)
  on appointment.appointments to authenticated;
grant all on all tables in schema appointment to service_role;

revoke all on function appointment.available_slots(uuid, uuid, date, date, uuid) from public, anon;
grant execute on function appointment.available_slots(uuid, uuid, date, date, uuid) to authenticated, service_role;
