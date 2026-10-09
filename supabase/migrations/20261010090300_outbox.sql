-- =============================================================================
-- Sprint 2 / Migration 14: transactional outbox for appointment / queue events.
-- Contract: /workspace/SPRINT2-CONTRACT.md §4 (D8).
--   * Written ONLY by DB triggers in the same transaction as the change (no client grants).
--   * Payloads carry ids / statuses / times only - no PHI (no names, phone, reason).
--   * Consumed by the Backend dispatcher as role hms_dispatcher through claim/complete/fail
--     RPCs; claims use FOR UPDATE SKIP LOCKED with a lease. At-least-once: dedupe on event_id.
-- =============================================================================

create schema if not exists messaging;
comment on schema messaging is 'Transactional outbox (integration events). No PHI.';
revoke all on schema messaging from public;

create table messaging.outbox (
  id              bigint generated always as identity primary key,
  event_id        uuid not null default gen_random_uuid(),
  tenant_id       uuid not null,
  aggregate_type  text not null,
  aggregate_id    uuid not null,
  event_type      text not null,
  payload         jsonb not null,
  occurred_at     timestamptz not null default now(),
  status          text not null default 'pending',
  attempts        integer not null default 0,
  available_at    timestamptz not null default now(),
  claimed_by      text,
  claimed_until   timestamptz,
  processed_at    timestamptz,
  last_error      text,
  constraint outbox_event_id_key unique (event_id),
  constraint outbox_status_valid check (status in ('pending', 'processing', 'done', 'dead')),
  constraint outbox_aggregate_type_valid check (aggregate_type in ('appointment', 'queue_entry')),
  constraint outbox_attempts_nonneg check (attempts >= 0),
  constraint outbox_last_error_len check (last_error is null or length(last_error) <= 2000)
);
create index outbox_claimable_idx on messaging.outbox (status, available_at, id) where status in ('pending', 'processing');
create index outbox_tenant_idx on messaging.outbox (tenant_id, occurred_at);

alter table messaging.outbox enable row level security;  -- no policies, no client grants
grant all on messaging.outbox to service_role;
grant usage on schema messaging to service_role;

-- ------------------------------------------------------------- internal enqueue ----
create or replace function messaging.enqueue(
  p_tenant_id uuid, p_aggregate_type text, p_aggregate_id uuid, p_event_type text, p_payload jsonb)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into messaging.outbox (tenant_id, aggregate_type, aggregate_id, event_type, payload)
  values (p_tenant_id, p_aggregate_type, p_aggregate_id, p_event_type, p_payload)
$$;
revoke all on function messaging.enqueue(uuid, text, uuid, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------- event triggers ----
create or replace function appointment.emit_appointment_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type text;
begin
  if tg_op = 'INSERT' then
    v_type := 'appointment.booked';
  elsif new.status is distinct from old.status then
    v_type := 'appointment.' || new.status;
  elsif new.starts_at is distinct from old.starts_at or new.ends_at is distinct from old.ends_at
        or new.practitioner_id is distinct from old.practitioner_id then
    v_type := 'appointment.rescheduled';
  else
    return null; -- e.g. reason edits: no event
  end if;

  perform messaging.enqueue(new.tenant_id, 'appointment', new.id, v_type, jsonb_build_object(
    'appointment_id', new.id,
    'tenant_id', new.tenant_id,
    'branch_id', new.branch_id,
    'practitioner_id', new.practitioner_id,
    'patient_id', new.patient_id,
    'starts_at', new.starts_at,
    'ends_at', new.ends_at,
    'status', new.status,
    'previous_status', case when tg_op = 'UPDATE' then old.status end));
  return null;
end;
$$;
revoke all on function appointment.emit_appointment_event() from public;

create trigger appointments_outbox after insert or update on appointment.appointments
  for each row execute function appointment.emit_appointment_event();

create or replace function appointment.emit_queue_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;
  perform messaging.enqueue(new.tenant_id, 'queue_entry', new.id,
    case when tg_op = 'INSERT' then 'queue.token_issued' else 'queue.status_changed' end,
    jsonb_build_object(
      'queue_entry_id', new.id,
      'tenant_id', new.tenant_id,
      'branch_id', new.branch_id,
      'queue_date', new.queue_date,
      'token_no', new.token_no,
      'patient_id', new.patient_id,
      'appointment_id', new.appointment_id,
      'practitioner_id', new.practitioner_id,
      'status', new.status,
      'previous_status', case when tg_op = 'UPDATE' then old.status end));
  return null;
end;
$$;
revoke all on function appointment.emit_queue_event() from public;

create trigger queue_entries_outbox after insert or update on appointment.queue_entries
  for each row execute function appointment.emit_queue_event();

-- ---------------------------------------------------------------- dispatcher role ----
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'hms_dispatcher') then
    create role hms_dispatcher nologin noinherit;
  end if;
end
$$;
comment on role hms_dispatcher is
  'Outbox dispatcher: may only claim/complete/fail outbox rows (EXECUTE on messaging RPCs). '
  'The API login reaches it via hms_api with SET LOCAL ROLE hms_dispatcher per transaction.';
grant hms_dispatcher to hms_api;
grant usage on schema messaging to hms_dispatcher;

-- ------------------------------------------------------------------ consumer RPCs ----
create or replace function messaging.claim_outbox(
  p_worker text, p_batch integer default 50, p_lease interval default '30 seconds')
returns setof messaging.outbox
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_worker is null or length(btrim(p_worker)) = 0 or length(p_worker) > 200 then
    raise exception 'worker id required (<= 200 chars)' using errcode = '22023';
  end if;
  if p_batch is null or p_batch < 1 or p_batch > 500 then
    raise exception 'batch must be 1..500' using errcode = '22023';
  end if;
  if p_lease is null or p_lease <= interval '0' or p_lease > interval '1 hour' then
    raise exception 'lease must be > 0 and <= 1 hour' using errcode = '22023';
  end if;

  -- expired leases that already used all attempts go to dead instead of being re-claimed
  update messaging.outbox o
     set status = 'dead', claimed_by = null, claimed_until = null,
         last_error = coalesce(o.last_error, 'lease expired after max attempts')
   where o.status = 'processing' and o.claimed_until < now() and o.attempts >= 10;

  return query
  with c as (
    select o.id
    from messaging.outbox o
    where (o.status = 'pending' and o.available_at <= now())
       or (o.status = 'processing' and o.claimed_until < now())
    order by o.id
    limit p_batch
    for update skip locked
  )
  update messaging.outbox o
     set status = 'processing',
         claimed_by = p_worker,
         claimed_until = now() + p_lease,
         attempts = o.attempts + 1
    from c
   where o.id = c.id
  returning o.*;
end;
$$;

create or replace function messaging.complete_outbox(p_id bigint, p_worker text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update messaging.outbox o
     set status = 'done', processed_at = now(), claimed_until = null
   where o.id = p_id and o.status = 'processing' and o.claimed_by = p_worker;
  if not found then
    raise exception 'outbox row not claimed by this worker' using errcode = 'P0002';
  end if;
end;
$$;

create or replace function messaging.fail_outbox(
  p_id bigint, p_worker text, p_error text, p_retry_in interval default '1 minute')
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_retry_in is null or p_retry_in < interval '0' or p_retry_in > interval '1 day' then
    raise exception 'retry_in must be 0..1 day' using errcode = '22023';
  end if;
  update messaging.outbox o
     set status = case when o.attempts >= 10 then 'dead' else 'pending' end,
         available_at = case when o.attempts >= 10 then o.available_at else now() + p_retry_in end,
         last_error = left(coalesce(p_error, ''), 2000),
         claimed_by = null,
         claimed_until = null
   where o.id = p_id and o.status = 'processing' and o.claimed_by = p_worker;
  if not found then
    raise exception 'outbox row not claimed by this worker' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function messaging.claim_outbox(text, integer, interval) from public, anon, authenticated;
revoke all on function messaging.complete_outbox(bigint, text) from public, anon, authenticated;
revoke all on function messaging.fail_outbox(bigint, text, text, interval) from public, anon, authenticated;
grant execute on function messaging.claim_outbox(text, integer, interval) to hms_dispatcher, service_role;
grant execute on function messaging.complete_outbox(bigint, text) to hms_dispatcher, service_role;
grant execute on function messaging.fail_outbox(bigint, text, text, interval) to hms_dispatcher, service_role;
