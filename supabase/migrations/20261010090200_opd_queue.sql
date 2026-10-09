-- =============================================================================
-- Sprint 2 / Migration 13: OPD queue - check-in (appointment or walk-in) and per-branch,
-- per-branch-local-day token numbers.
-- Contract: /workspace/SPRINT2-CONTRACT.md §3 (D6, D7, D11).
-- All writes go through appointment.check_in(), appointment.check_in_walk_in() and
-- appointment.set_queue_status(); clients have no DML grants on the queue tables.
-- =============================================================================

create table appointment.queue_counters (
  tenant_id   uuid not null,
  branch_id   uuid not null,
  queue_date  date not null,
  last_token  integer not null,
  constraint queue_counters_pkey primary key (tenant_id, branch_id, queue_date),
  constraint queue_counters_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete cascade,
  constraint queue_counters_positive check (last_token > 0)
);
comment on table appointment.queue_counters is
  'Token counter per (tenant, branch, branch-local date). Written only by the check-in RPCs (upsert = row lock).';

create table appointment.queue_entries (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references identity.tenants (id) on delete restrict,
  branch_id        uuid not null,
  queue_date       date not null,
  token_no         integer not null,
  patient_id       uuid not null,
  appointment_id   uuid,
  practitioner_id  uuid,
  status           text not null default 'waiting',
  checked_in_at    timestamptz not null default now(),
  called_at        timestamptz,
  completed_at     timestamptz,
  cancelled_at     timestamptz,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint queue_entries_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete restrict,
  constraint queue_entries_patient_same_tenant
    foreign key (tenant_id, patient_id) references patient.patients (tenant_id, id) on delete restrict,
  constraint queue_entries_appointment_same_tenant
    foreign key (tenant_id, appointment_id) references appointment.appointments (tenant_id, id) on delete restrict,
  constraint queue_entries_practitioner_same_tenant
    foreign key (tenant_id, practitioner_id) references appointment.practitioners (tenant_id, id) on delete restrict,
  constraint queue_entries_token_positive check (token_no > 0),
  constraint queue_entries_status_valid check (status in ('waiting', 'in_consultation', 'done', 'cancelled')),
  constraint queue_entries_token_key unique (tenant_id, branch_id, queue_date, token_no),
  constraint queue_entries_tenant_id_id_key unique (tenant_id, id)
);
-- an appointment is checked in at most once
create unique index queue_entries_appointment_key on appointment.queue_entries (appointment_id) where appointment_id is not null;
-- D11: at most one ACTIVE entry per patient per branch per branch-local day (both paths)
create unique index queue_entries_one_active_per_patient
  on appointment.queue_entries (tenant_id, branch_id, queue_date, patient_id) where status in ('waiting', 'in_consultation');
create index queue_entries_board_idx on appointment.queue_entries (tenant_id, branch_id, queue_date, status, token_no);

create trigger queue_entries_audit_columns before insert or update on appointment.queue_entries
  for each row execute function audit.stamp_audit_columns();
create trigger queue_entries_tenant_immutable before update on appointment.queue_entries
  for each row execute function audit.prevent_tenant_change();
create trigger queue_entries_audit_log after insert or update or delete on appointment.queue_entries
  for each row execute function audit.log_row_change();

-- -------------------------------------------------------- internal: token issue ----
-- Not executable by any client role. Callers have already authorized and validated.
create or replace function appointment.issue_queue_token(
  p_tenant_id uuid, p_branch_id uuid, p_patient_id uuid, p_appointment_id uuid, p_practitioner_id uuid)
returns table (queue_entry_id uuid, token_no integer, queue_date date)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tz    text;
  v_date  date;
  v_token integer;
  v_id    uuid;
begin
  select b.timezone into strict v_tz from identity.branches b where b.tenant_id = p_tenant_id and b.id = p_branch_id;
  v_date := (now() at time zone v_tz)::date;

  if exists (select 1 from appointment.queue_entries q
             where q.tenant_id = p_tenant_id and q.branch_id = p_branch_id and q.queue_date = v_date
               and q.patient_id = p_patient_id and q.status in ('waiting', 'in_consultation')) then
    raise exception 'patient already has an active queue entry at this branch today' using errcode = '23505';
  end if;

  insert into appointment.queue_counters as c (tenant_id, branch_id, queue_date, last_token)
  values (p_tenant_id, p_branch_id, v_date, 1)
  on conflict on constraint queue_counters_pkey do update set last_token = c.last_token + 1
  returning c.last_token into v_token;

  insert into appointment.queue_entries (tenant_id, branch_id, queue_date, token_no, patient_id, appointment_id, practitioner_id)
  values (p_tenant_id, p_branch_id, v_date, v_token, p_patient_id, p_appointment_id, p_practitioner_id)
  returning id into v_id;

  queue_entry_id := v_id;
  token_no := v_token;
  queue_date := v_date;
  return next;
end;
$$;
revoke all on function appointment.issue_queue_token(uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated;

-- ------------------------------------------------------------------- check_in ----
create or replace function appointment.check_in(
  p_tenant_id uuid,
  p_branch_id uuid,
  p_patient_id uuid,
  p_appointment_id uuid default null,
  p_practitioner_id uuid default null)
returns table (queue_entry_id uuid, token_no integer, queue_date date)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_appt record;
  v_tz text;
  v_practitioner uuid := p_practitioner_id;
begin
  if not identity.has_tenant_role(p_tenant_id, array['tenant_admin', 'receptionist', 'nurse'])
     or not identity.can_access_branch(p_tenant_id, p_branch_id) then
    raise exception 'not permitted to check in at this branch' using errcode = '42501';
  end if;

  if not exists (select 1 from patient.patients p
                 where p.tenant_id = p_tenant_id and p.id = p_patient_id and p.deleted_at is null) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;

  if p_appointment_id is not null then
    select a.id, a.status, a.starts_at, a.practitioner_id into v_appt
    from appointment.appointments a
    where a.tenant_id = p_tenant_id and a.id = p_appointment_id
      and a.branch_id = p_branch_id and a.patient_id = p_patient_id
    for update;
    if v_appt.id is null then
      raise exception 'appointment not found' using errcode = 'P0002';
    end if;
    if exists (select 1 from appointment.queue_entries q where q.appointment_id = v_appt.id) then
      raise exception 'appointment already checked in' using errcode = '23505';
    end if;
    if v_appt.status <> 'booked' then
      raise exception 'invalid_transition:%->checked_in', v_appt.status using errcode = '23514';
    end if;
    select b.timezone into v_tz from identity.branches b where b.id = p_branch_id;
    if (v_appt.starts_at at time zone v_tz)::date <> (now() at time zone v_tz)::date then
      raise exception 'appointment is not for today at this branch' using errcode = '55000';
    end if;
    v_practitioner := coalesce(p_practitioner_id, v_appt.practitioner_id);
  end if;

  if v_practitioner is not null and not exists (
       select 1 from appointment.practitioners pr
       where pr.tenant_id = p_tenant_id and pr.id = v_practitioner and pr.is_active) then
    raise exception 'practitioner not found' using errcode = 'P0002';
  end if;

  if p_appointment_id is not null then
    perform set_config('appointment.check_in', p_appointment_id::text, true);
    update appointment.appointments set status = 'checked_in' where id = p_appointment_id;
    perform set_config('appointment.check_in', '', true);
  end if;

  return query select * from appointment.issue_queue_token(p_tenant_id, p_branch_id, p_patient_id, p_appointment_id, v_practitioner);
end;
$$;

-- -------------------------------------------------------- check_in_walk_in (D11) ----
create or replace function appointment.check_in_walk_in(
  p_branch_id uuid,
  p_patient_id uuid,
  p_practitioner_id uuid default null)
returns table (queue_entry_id uuid, token_no integer, queue_date date)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  -- tenant comes from the branch, never from input; another tenant's branch looks unknown
  select b.tenant_id into v_tenant from identity.branches b where b.id = p_branch_id;
  if v_tenant is null or v_tenant not in (select identity.current_tenant_ids()) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;

  if not identity.has_tenant_role(v_tenant, array['tenant_admin', 'receptionist', 'nurse'])
     or not identity.can_access_branch(v_tenant, p_branch_id) then
    raise exception 'not permitted to check in at this branch' using errcode = '42501';
  end if;

  if not exists (select 1 from patient.patients p
                 where p.tenant_id = v_tenant and p.id = p_patient_id and p.deleted_at is null) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;

  if p_practitioner_id is not null and not exists (
       select 1 from appointment.practitioners pr
       where pr.tenant_id = v_tenant and pr.id = p_practitioner_id and pr.is_active) then
    raise exception 'practitioner not found' using errcode = 'P0002';
  end if;

  return query select * from appointment.issue_queue_token(v_tenant, p_branch_id, p_patient_id, null, p_practitioner_id);
end;
$$;

-- ------------------------------------------------------------- set_queue_status ----
create or replace function appointment.set_queue_status(p_queue_entry_id uuid, p_status text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_q record;
  v_ok boolean;
  v_appt_status text;
begin
  select q.id, q.tenant_id, q.branch_id, q.status, q.appointment_id into v_q
  from appointment.queue_entries q where q.id = p_queue_entry_id
  for update;

  if v_q.id is null
     or not identity.has_tenant_role(v_q.tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing'])
     or not identity.can_access_branch(v_q.tenant_id, v_q.branch_id) then
    raise exception 'queue entry not found' using errcode = 'P0002';
  end if;

  if not (identity.has_tenant_role(v_q.tenant_id, array['tenant_admin', 'receptionist', 'nurse'])
          or (p_status in ('in_consultation', 'done') and identity.has_tenant_role(v_q.tenant_id, array['doctor']))) then
    raise exception 'not permitted to set queue status %', p_status using errcode = '42501';
  end if;

  v_ok := case
    when v_q.status = 'waiting' and p_status in ('in_consultation', 'cancelled') then true
    when v_q.status = 'in_consultation' and p_status in ('done', 'cancelled') then true
    else false
  end;
  if not v_ok then
    raise exception 'invalid_transition:%->%', v_q.status, coalesce(p_status, 'null') using errcode = '23514';
  end if;

  update appointment.queue_entries q
     set status = p_status,
         called_at = case when p_status = 'in_consultation' then now() else q.called_at end,
         completed_at = case when p_status = 'done' then now() else q.completed_at end,
         cancelled_at = case when p_status = 'cancelled' then now() else q.cancelled_at end
   where q.id = v_q.id;

  if v_q.appointment_id is not null then
    v_appt_status := case p_status when 'in_consultation' then 'in_consultation'
                                   when 'done' then 'completed'
                                   when 'cancelled' then 'cancelled' end;
    perform set_config('appointment.queue_sync', v_q.appointment_id::text, true);
    update appointment.appointments a set status = v_appt_status
     where a.id = v_q.appointment_id and a.status is distinct from v_appt_status;
    perform set_config('appointment.queue_sync', '', true);
  end if;
end;
$$;

-- ---------------------------------------------------------------------- RLS ----
alter table appointment.queue_counters enable row level security;  -- no policies: RPC-only
alter table appointment.queue_entries  enable row level security;

create policy queue_entries_select_branch on appointment.queue_entries
  for select to authenticated
  using (identity.has_tenant_role(tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing'])
         and identity.can_access_branch(tenant_id, branch_id));

grant select on appointment.queue_entries to authenticated;
grant all on appointment.queue_counters, appointment.queue_entries to service_role;

revoke all on function appointment.check_in(uuid, uuid, uuid, uuid, uuid) from public, anon;
revoke all on function appointment.check_in_walk_in(uuid, uuid, uuid) from public, anon;
revoke all on function appointment.set_queue_status(uuid, text) from public, anon;
grant execute on function appointment.check_in(uuid, uuid, uuid, uuid, uuid) to authenticated, service_role;
grant execute on function appointment.check_in_walk_in(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function appointment.set_queue_status(uuid, text) to authenticated, service_role;
