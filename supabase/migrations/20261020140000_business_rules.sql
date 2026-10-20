-- Business rules approved by the product owner on 2026-10-20 (business-logic audit gaps G3, G7, H3,
-- C5, B5, A14 + ABHA number). Additive: new columns are nullable / defaulted, existing rows are not
-- rewritten (except the one-time end-of-day close of stale queue entries, which is idempotent).
--   1. Working hours: appointment.assert_bookable_window_v2(..., p_override) rejects a booking outside
--      the practitioner's active schedule (branch-local) unless the caller may override
--      (appointments.override_hours, tenant_admin) and asked to. appointments.hours_override records
--      it; the existing row audit trigger puts every override in audit.audit_log.
--   2. Booking: nurses get appointments.book; doctors get appointments.book_followup_own (a follow-up
--      of an appointment of their own linked practitioner). RLS insert policy updated to match.
--   3. Follow-ups: appointments.parent_appointment_id (same tenant via composite FK; same patient via
--      the transition trigger).
--   4. End of day: appointment.close_stale_queues() marks queue entries still 'waiting' on an earlier
--      branch-local day as no_show (and their checked-in appointment as no_show). pg_cron runs it every
--      15 minutes when the extension is installed (Supabase free tier); idempotent.
--   5. Branch names unique per tenant: case/space-insensitive, soft-deleted rows ignored.
--   6. A tenant always keeps one active tenant_admin membership (constraint trigger, 55000 last_admin).
--   7. Outbox: tenant.created / tenant.approved / tenant.suspended / tenant.reactivated events.
--   8. patient.patients.abha_number (optional, XX-XXXX-XXXX-XXXX, unique per tenant among live rows).
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ------------------------------------------------------------------ RBAC ----
insert into identity.role_permissions (role, permission) values
  ('nurse', 'appointments.book'),
  ('doctor', 'appointments.book_followup_own'),
  ('tenant_admin', 'appointments.override_hours')
on conflict (role, permission) do update set is_deleted = false;

-- ------------------------------------------------------ appointment columns ----
alter table appointment.appointments
  add column parent_appointment_id uuid,
  add column hours_override boolean not null default false,
  add constraint appointments_parent_same_tenant
    foreign key (tenant_id, parent_appointment_id) references appointment.appointments (tenant_id, id) on delete restrict,
  add constraint appointments_parent_not_self check (parent_appointment_id is null or parent_appointment_id <> id);
grant insert (parent_appointment_id, hours_override), update (hours_override) on appointment.appointments to authenticated;
create index appointments_parent_idx on appointment.appointments (tenant_id, parent_appointment_id) where parent_appointment_id is not null;

-- appointments already have a row audit trigger (appointments_audit_log), so hours_override lands in audit.audit_log.

-- follow-up: same patient as the parent; parent is immutable after insert
create or replace function appointment.check_parent_appointment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_parent_patient uuid;
begin
  if tg_op = 'UPDATE' then
    if new.parent_appointment_id is distinct from old.parent_appointment_id then
      raise exception 'parent_appointment_id cannot change' using errcode = '22023';
    end if;
    if new.hours_override is distinct from old.hours_override and not new.hours_override then
      raise exception 'hours_override cannot be cleared' using errcode = '22023';
    end if;
    if new.hours_override and not old.hours_override and auth.uid() is not null
       and not identity.has_tenant_permission(new.tenant_id, 'appointments.override_hours') then
      raise exception 'only admins can book outside working hours' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.hours_override and auth.uid() is not null
     and not identity.has_tenant_permission(new.tenant_id, 'appointments.override_hours') then
    raise exception 'only admins can book outside working hours' using errcode = '42501';
  end if;
  if new.parent_appointment_id is null then
    return new;
  end if;
  select a.patient_id into v_parent_patient from appointment.appointments a
   where a.tenant_id = new.tenant_id and a.id = new.parent_appointment_id;
  if v_parent_patient is null then
    raise exception 'parent appointment not found' using errcode = 'P0002';
  end if;
  if v_parent_patient <> new.patient_id then
    raise exception 'follow_up_patient_mismatch: a follow-up must be for the same patient as the earlier visit' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function appointment.check_parent_appointment() from public, anon, authenticated;
create trigger appointments_parent_check before insert or update on appointment.appointments
  for each row execute function appointment.check_parent_appointment();

-- true when the parent appointment belongs to a practitioner linked to the caller
create or replace function appointment.is_own_followup_parent(p_tenant_id uuid, p_parent_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from appointment.appointments a
      join appointment.practitioners p on p.tenant_id = a.tenant_id and p.id = a.practitioner_id
     where a.tenant_id = p_tenant_id and a.id = p_parent_id and p.user_id = auth.uid() and not p.is_deleted)
$$;
revoke all on function appointment.is_own_followup_parent(uuid, uuid) from public, anon;
grant execute on function appointment.is_own_followup_parent(uuid, uuid) to authenticated;

drop policy appointments_insert_writers on appointment.appointments;
create policy appointments_insert_writers on appointment.appointments
  for insert to authenticated
  with check (identity.can_access_branch(tenant_id, branch_id)
              and (identity.has_tenant_permission(tenant_id, 'appointments.book')
                   or (identity.has_tenant_permission(tenant_id, 'appointments.book_followup_own')
                       and parent_appointment_id is not null
                       and appointment.is_own_followup_parent(tenant_id, parent_appointment_id)
                       and exists (select 1 from appointment.practitioners p
                                    where p.tenant_id = appointments.tenant_id and p.id = appointments.practitioner_id
                                      and p.user_id = auth.uid()))));

-- ------------------------------------------------------------ working hours ----
create or replace function appointment.assert_bookable_window_v2(
  p_tenant_id uuid, p_branch_id uuid, p_practitioner_id uuid, p_starts timestamptz, p_ends timestamptz, p_override boolean)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_zone text;
  v_ls timestamp;
  v_le timestamp;
begin
  perform appointment.assert_bookable_window(p_tenant_id, p_branch_id, p_practitioner_id, p_starts, p_ends);
  if coalesce(p_override, false) then
    if not identity.has_tenant_permission(p_tenant_id, 'appointments.override_hours') then
      raise exception 'only admins can book outside working hours' using errcode = '42501';
    end if;
    return;
  end if;
  v_zone := identity.branch_time_zone_v1(p_branch_id);
  v_ls := p_starts at time zone v_zone;
  v_le := p_ends at time zone v_zone;
  if not exists (
      select 1 from appointment.schedules s
       where s.tenant_id = p_tenant_id and s.branch_id = p_branch_id and s.practitioner_id = p_practitioner_id
         and s.is_active and not s.is_deleted
         and s.weekday = extract(isodow from v_ls)
         and v_ls::date = v_le::date
         and s.valid_from <= v_ls::date and (s.valid_to is null or s.valid_to >= v_ls::date)
         and v_ls::time >= s.start_time and v_le::time <= s.end_time) then
    raise exception 'outside_working_hours: the doctor is not working at that time' using errcode = '22023';
  end if;
end;
$$;
revoke all on function appointment.assert_bookable_window_v2(uuid, uuid, uuid, timestamptz, timestamptz, boolean) from public, anon;
grant execute on function appointment.assert_bookable_window_v2(uuid, uuid, uuid, timestamptz, timestamptz, boolean) to authenticated;

-- ----------------------------------------------------------- end of day ----
alter table appointment.queue_entries drop constraint queue_entries_status_valid;
alter table appointment.queue_entries add constraint queue_entries_status_valid
  check (status in ('waiting', 'in_consultation', 'done', 'cancelled', 'no_show'));

-- checked_in -> no_show is allowed only through the end-of-day close (session flag)
create or replace function appointment.enforce_appointment_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_via_checkin boolean;
  v_via_queue   boolean;
  v_via_eod     boolean;
  v_ok          boolean;
begin
  if tg_op = 'INSERT' then
    if new.status is distinct from 'booked' then
      raise exception 'invalid_transition:new->%', new.status using errcode = '23514';
    end if;
    new.checked_in_at := null; new.started_at := null; new.completed_at := null; new.cancelled_at := null;
    perform appointment.assert_tenant_refs(new.tenant_id, new.branch_id);
    if not patient.patient_exists_v1(new.tenant_id, new.patient_id) then
      raise exception 'patient not found' using errcode = 'P0002';
    end if;
    perform appointment.assert_practitioner_bookable(new.tenant_id, new.practitioner_id);
    return new;
  end if;

  new.checked_in_at := old.checked_in_at; new.started_at := old.started_at;
  new.completed_at := old.completed_at;   new.cancelled_at := old.cancelled_at;

  if old.status <> 'booked' and (
       new.starts_at is distinct from old.starts_at or new.ends_at is distinct from old.ends_at
       or new.practitioner_id is distinct from old.practitioner_id or new.patient_id is distinct from old.patient_id
       or new.branch_id is distinct from old.branch_id) then
    raise exception 'invalid_transition:reschedule_not_booked' using errcode = '23514';
  end if;

  if new.patient_id is distinct from old.patient_id
     and not patient.patient_exists_v1(new.tenant_id, new.patient_id) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if new.patient_id is distinct from old.patient_id and new.parent_appointment_id is not null then
    raise exception 'follow_up_patient_mismatch: a follow-up must stay with the same patient' using errcode = '22023';
  end if;

  if new.practitioner_id is distinct from old.practitioner_id then
    perform appointment.assert_practitioner_bookable(new.tenant_id, new.practitioner_id);
  end if;

  if new.status is not distinct from old.status then
    return new;
  end if;

  v_via_checkin := coalesce(current_setting('appointment.check_in', true), '') = old.id::text;
  v_via_queue   := coalesce(current_setting('appointment.queue_sync', true), '') = old.id::text;
  v_via_eod     := coalesce(current_setting('appointment.eod_close', true), '') = 'on';

  v_ok := case
    when old.status = 'booked' and new.status = 'checked_in' then v_via_checkin
    when old.status = 'booked' and new.status = 'cancelled' then true
    when old.status = 'booked' and new.status = 'no_show' then now() >= old.starts_at
    when old.status = 'checked_in' and new.status = 'no_show' then v_via_eod
    when old.status = 'checked_in' and new.status in ('in_consultation', 'cancelled') then true
    when old.status = 'in_consultation' and new.status = 'completed' then true
    when old.status = 'in_consultation' and new.status = 'cancelled' then v_via_queue
    else false
  end;
  if not v_ok then
    raise exception 'invalid_transition:%->%', old.status, new.status using errcode = '23514';
  end if;

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

-- Owner-only job. Branch-local "today" uses the branch zone (tenant zone unless overridden).
create or replace function appointment.close_stale_queues()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  r record;
begin
  perform set_config('appointment.eod_close', 'on', true);
  for r in
    select q.id, q.tenant_id, q.appointment_id
      from appointment.queue_entries q
     where q.status = 'waiting' and not q.is_deleted
       and q.queue_date < identity.branch_local_date_v1(q.branch_id)
     for update of q skip locked
  loop
    update appointment.queue_entries set status = 'no_show', cancelled_at = now() where id = r.id;
    if r.appointment_id is not null then
      update appointment.appointments set status = 'no_show'
       where tenant_id = r.tenant_id and id = r.appointment_id and status = 'checked_in';
    end if;
    v_count := v_count + 1;
  end loop;
  perform set_config('appointment.eod_close', '', true);
  return v_count;
end;
$$;
revoke all on function appointment.close_stale_queues() from public, anon, authenticated;
comment on function appointment.close_stale_queues() is
  'End-of-day close: queue entries still waiting on an earlier branch-local day become no_show. pg_cron, every 15 min.';

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('hms-close-stale-queues', '*/15 * * * *', 'select appointment.close_stale_queues()');
  end if;
end
$$;

-- --------------------------------------------------- unique branch names ----
create unique index branches_tenant_name_key on identity.branches (tenant_id, lower(btrim(name))) where not is_deleted;

-- -------------------------------------------------------------- last admin ----
create or replace function identity.keep_last_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role = 'tenant_admin' and old.status = 'active' and not old.is_deleted
     and (tg_op = 'DELETE' or new.role <> 'tenant_admin' or new.status <> 'active' or new.is_deleted)
     and exists (select 1 from identity.tenants t where t.id = old.tenant_id and not t.is_deleted)
     and not exists (select 1 from identity.memberships m
                      where m.tenant_id = old.tenant_id and m.role = 'tenant_admin' and m.status = 'active' and not m.is_deleted) then
    raise exception 'last_admin: a hospital must keep at least one active admin' using errcode = '55000';
  end if;
  return null;
end;
$$;
revoke all on function identity.keep_last_admin() from public, anon, authenticated;
create constraint trigger memberships_keep_last_admin after update or delete on identity.memberships
  deferrable initially immediate
  for each row execute function identity.keep_last_admin();

-- ---------------------------------------------------------- tenant events ----
alter table messaging.outbox drop constraint outbox_aggregate_type_valid;
alter table messaging.outbox add constraint outbox_aggregate_type_valid check (aggregate_type in ('appointment', 'queue_entry', 'tenant'));
-- tenant events are produced by the identity service (no consumer yet: they wait as pending, which is the log)
create or replace function messaging.set_outbox_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.source_service := case new.aggregate_type
    when 'appointment' then 'scheduling'
    when 'queue_entry' then 'scheduling'
    when 'tenant' then 'identity'
  end;
  if new.source_service is null then
    raise exception 'no owning service for aggregate type %', new.aggregate_type using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function messaging.set_outbox_source() from public;

create or replace function identity.emit_tenant_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type text;
begin
  if tg_op = 'INSERT' then
    v_type := 'tenant.created';
  elsif new.status is distinct from old.status then
    v_type := case new.status when 'suspended' then 'tenant.suspended' when 'active' then 'tenant.reactivated' else 'tenant.' || new.status end;
  else
    return null;
  end if;
  perform messaging.enqueue(new.id, 'tenant', new.id, v_type, jsonb_build_object(
    'tenant_id', new.id, 'code', new.code, 'status', new.status,
    'previous_status', case when tg_op = 'UPDATE' then old.status end));
  return null;
end;
$$;
revoke all on function identity.emit_tenant_event() from public, anon, authenticated;
create trigger tenants_outbox after insert or update of status on identity.tenants
  for each row execute function identity.emit_tenant_event();

create or replace function identity.emit_tenant_approved_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform messaging.enqueue(new.tenant_id, 'tenant', new.tenant_id, 'tenant.approved', jsonb_build_object(
    'tenant_id', new.tenant_id, 'signup_request_id', new.id));
  return null;
end;
$$;
revoke all on function identity.emit_tenant_approved_event() from public, anon, authenticated;
create trigger tenant_signup_requests_outbox after update of status on identity.tenant_signup_requests
  for each row when (new.status = 'approved' and old.status is distinct from 'approved' and new.tenant_id is not null)
  execute function identity.emit_tenant_approved_event();

-- --------------------------------------------------------------- ABHA ----
alter table patient.patients
  add column abha_number text,
  add constraint patients_abha_format check (abha_number is null or abha_number ~ '^[0-9]{2}-[0-9]{4}-[0-9]{4}-[0-9]{4}$');
grant insert (abha_number), update (abha_number) on patient.patients to authenticated;
create unique index patients_tenant_abha_key on patient.patients (tenant_id, abha_number) where abha_number is not null and not is_deleted;
