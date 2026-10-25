-- cross-schema: approved (messaging.dispatch_receipt select policy calls
-- identity.has_tenant_permission. Dispatcher functions do not read other schemas.
-- The tenant id is copied from the outbox row, never from a client argument alone.)
-- Reliable outbox dispatch (BUG-48). Claim stays FOR UPDATE SKIP LOCKED and is scoped
-- to the calling service. One aggregate is delivered in id order. Email rows stay with
-- hms_mailer. The worker is off until Outbox:Dispatcher:Enabled is set; DryRun defaults
-- to true so the first enablement only reports the backlog.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

alter table messaging.outbox add column if not exists processed_on timestamptz;
update messaging.outbox
   set processed_on = processed_at
 where processed_at is not null and processed_on is null;
comment on column messaging.outbox.processed_on is
  'When the row was finished: delivered, dead-lettered, or skipped as stale. Null while it can still be retried.';

create index if not exists outbox_aggregate_head_idx
  on messaging.outbox (tenant_id, aggregate_type, aggregate_id, id)
  where status in ('pending', 'processing');

-- Owning services dispatch their own rows. Inventory has no outbox aggregate.
-- The legacy hms_api login stays revoked (B1).
grant hms_dispatcher to hms_svc_identity;
grant hms_dispatcher to hms_svc_patients;
grant hms_dispatcher to hms_svc_billing;
revoke hms_dispatcher from hms_svc_inventory;
revoke hms_dispatcher from hms_api;

comment on role hms_dispatcher is
  'Outbox dispatcher. SET ROLE from the owning service login only. claim/complete/fail are limited to that login''s source_service. Not granted to hms_api or hms_svc_inventory.';

-- ---------------------------------------------------------------- ordering ----
create or replace function messaging.claim_outbox(
  p_worker text, p_batch integer default 50, p_lease interval default '30 seconds')
returns setof messaging.outbox
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_sources text[] := messaging.caller_sources();
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

  -- email_message is claimed only by messaging.claim_email_outbox (hms_mailer).
  update messaging.outbox o
     set status = 'dead',
         claimed_by = null,
         claimed_until = null,
         processed_on = coalesce(o.processed_on, pg_catalog.now()),
         processed_at = coalesce(o.processed_at, pg_catalog.now()),
         last_error = coalesce(o.last_error, 'lease expired after max attempts')
   where o.aggregate_type <> 'email_message'
     and o.status = 'processing'
     and o.claimed_until < pg_catalog.now()
     and o.attempts >= 10
     and o.source_service = any (v_sources);

  return query
  with c as (
    select o.id
    from messaging.outbox o
    where o.source_service = any (v_sources)
      and o.aggregate_type <> 'email_message'
      and ((o.status = 'pending' and o.available_at <= pg_catalog.now())
        or (o.status = 'processing' and o.claimed_until < pg_catalog.now()))
      and not exists (
        select 1
        from messaging.outbox earlier
        where earlier.tenant_id = o.tenant_id
          and earlier.aggregate_type = o.aggregate_type
          and earlier.aggregate_id = o.aggregate_id
          and earlier.id < o.id
          and earlier.status in ('pending', 'processing'))
    order by o.id
    limit p_batch
    for update skip locked
  )
  update messaging.outbox o
     set status = 'processing',
         claimed_by = p_worker,
         claimed_until = pg_catalog.now() + p_lease,
         attempts = o.attempts + 1
    from c
   where o.id = c.id
  returning o.*;
end;
$$;

create or replace function messaging.claim_email_outbox(
  p_worker text, p_batch integer default 20, p_lease interval default '60 seconds')
returns setof messaging.outbox
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_sources text[] := messaging.caller_sources();
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

  update messaging.outbox o
     set status = 'dead',
         claimed_by = null,
         claimed_until = null,
         processed_on = coalesce(o.processed_on, pg_catalog.now()),
         processed_at = coalesce(o.processed_at, pg_catalog.now()),
         last_error = coalesce(o.last_error, 'lease expired after max attempts')
   where o.aggregate_type = 'email_message'
     and o.status = 'processing'
     and o.claimed_until < pg_catalog.now()
     and o.attempts >= 10
     and o.source_service = any (v_sources);

  return query
  with c as (
    select o.id
    from messaging.outbox o
    where o.aggregate_type = 'email_message'
      and o.source_service = any (v_sources)
      and ((o.status = 'pending' and o.available_at <= pg_catalog.now())
        or (o.status = 'processing' and o.claimed_until < pg_catalog.now()))
      and not exists (
        select 1
        from messaging.outbox earlier
        where earlier.tenant_id = o.tenant_id
          and earlier.aggregate_type = o.aggregate_type
          and earlier.aggregate_id = o.aggregate_id
          and earlier.id < o.id
          and earlier.status in ('pending', 'processing'))
    order by o.id
    limit p_batch
    for update skip locked
  )
  update messaging.outbox o
     set status = 'processing',
         claimed_by = p_worker,
         claimed_until = pg_catalog.now() + p_lease,
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
     set status = 'done',
         processed_on = pg_catalog.now(),
         processed_at = pg_catalog.now(),
         claimed_until = null,
         last_error = null
   where o.id = p_id
     and o.status = 'processing'
     and o.claimed_by = p_worker
     and o.source_service = any (messaging.caller_sources());
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
         available_at = case when o.attempts >= 10 then o.available_at else pg_catalog.now() + p_retry_in end,
         processed_on = case when o.attempts >= 10 then pg_catalog.now() else o.processed_on end,
         processed_at = case when o.attempts >= 10 then pg_catalog.now() else o.processed_at end,
         last_error = left(coalesce(p_error, ''), 2000),
         claimed_by = null,
         claimed_until = null
   where o.id = p_id
     and o.status = 'processing'
     and o.claimed_by = p_worker
     and o.source_service = any (messaging.caller_sources());
  if not found then
    raise exception 'outbox row not claimed by this worker' using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------- receipts ----
-- One row per event_id that this dispatcher has handed to its publisher. A replica
-- that re-claims after a lost ack sees the receipt and does not publish again.
create table messaging.dispatch_receipt (
  event_id        uuid primary key,
  tenant_id       uuid not null,
  source_service  text not null,
  created_on      timestamptz not null default now(),
  created_by      uuid not null,
  updated_on      timestamptz not null default now(),
  updated_by      uuid not null,
  is_deleted      boolean not null default false,
  constraint dispatch_receipt_source_valid check (
    source_service in ('identity', 'patients', 'scheduling', 'billing'))
);
comment on table messaging.dispatch_receipt is
  'Idempotency mark for one outbox event_id. No payload. Tenant id is copied from the outbox row.';
create index dispatch_receipt_tenant_idx on messaging.dispatch_receipt (tenant_id) where not is_deleted;

alter table messaging.dispatch_receipt enable row level security;
revoke all on messaging.dispatch_receipt from public, anon, authenticated;
grant usage on schema messaging to authenticated;
grant select on messaging.dispatch_receipt to authenticated;
create policy dispatch_receipt_tenant_read on messaging.dispatch_receipt
  for select to authenticated
  using (identity.has_tenant_permission(tenant_id, 'members.manage'));

create trigger dispatch_receipt_audit_columns
  before insert or update on messaging.dispatch_receipt
  for each row execute function audit.stamp_audit_columns();

create or replace function messaging.outbox_was_dispatched(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from messaging.dispatch_receipt r
    where r.event_id = p_event_id
      and not r.is_deleted
      and r.source_service = any (messaging.caller_sources()))
$$;

create or replace function messaging.note_outbox_dispatched(p_event_id uuid, p_tenant_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_event_id is null or p_tenant_id is null then
    raise exception 'event and tenant are required' using errcode = '22023';
  end if;
  if exists (
    select 1 from messaging.dispatch_receipt r
    where r.event_id = p_event_id and not r.is_deleted
  ) then
    return;
  end if;
  insert into messaging.dispatch_receipt (event_id, tenant_id, source_service)
  select o.event_id, o.tenant_id, o.source_service
  from messaging.outbox o
  where o.event_id = p_event_id
    and o.tenant_id = p_tenant_id
    and o.source_service = any (messaging.caller_sources());
  if not found then
    raise exception 'outbox event is not visible to this service' using errcode = '42501';
  end if;
end;
$$;

-- ---------------------------------------------------------------- health / drain ----
-- Appointment and queue events older than 2 days are past the visit window.
-- Other domain events older than 7 days already happened in the owning service.
-- email_message is never stale here: the identity mailer still sends it.
create or replace function messaging.outbox_row_is_stale(p_aggregate_type text, p_occurred_at timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case
    when p_aggregate_type = 'email_message' then false
    when p_aggregate_type in ('appointment', 'queue_entry')
      then p_occurred_at < pg_catalog.now() - interval '2 days'
    else p_occurred_at < pg_catalog.now() - interval '7 days'
  end
$$;

create or replace function messaging.outbox_backlog()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'pending', count(*) filter (where o.status = 'pending'),
    'processing', count(*) filter (where o.status = 'processing'),
    'dead', count(*) filter (where o.status = 'dead'),
    'stalePending', count(*) filter (
      where o.status = 'pending' and messaging.outbox_row_is_stale(o.aggregate_type, o.occurred_at)),
    'oldestPendingSeconds', floor(extract(epoch from (
      pg_catalog.now() - min(o.occurred_at) filter (where o.status = 'pending')))))
  from messaging.outbox o
  where o.source_service = any (messaging.caller_sources())
    and o.aggregate_type <> 'email_message'
$$;

-- p_apply false counts the rows that would be skipped. p_apply true marks them dead,
-- records processed_on, and does not deliver them. Attempts stay 0.
create or replace function messaging.skip_stale_outbox(p_apply boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_stale bigint;
  v_skipped bigint := 0;
begin
  select count(*) into v_stale
  from messaging.outbox o
  where o.status = 'pending'
    and o.attempts = 0
    and o.aggregate_type <> 'email_message'
    and o.source_service = any (messaging.caller_sources())
    and messaging.outbox_row_is_stale(o.aggregate_type, o.occurred_at);

  if coalesce(p_apply, false) then
    update messaging.outbox o
       set status = 'dead',
           last_error = 'skipped: stale before dispatcher enablement',
           processed_on = pg_catalog.now(),
           processed_at = pg_catalog.now(),
           claimed_by = null,
           claimed_until = null
     where o.status = 'pending'
       and o.attempts = 0
       and o.aggregate_type <> 'email_message'
       and o.source_service = any (messaging.caller_sources())
       and messaging.outbox_row_is_stale(o.aggregate_type, o.occurred_at);
    get diagnostics v_skipped = row_count;
  end if;

  return jsonb_build_object('apply', coalesce(p_apply, false), 'stale', v_stale, 'skipped', v_skipped);
end;
$$;

revoke all on function messaging.outbox_row_is_stale(text, timestamptz) from public, anon, authenticated;
revoke all on function messaging.outbox_was_dispatched(uuid) from public, anon, authenticated;
revoke all on function messaging.note_outbox_dispatched(uuid, uuid) from public, anon, authenticated;
revoke all on function messaging.outbox_backlog() from public, anon, authenticated;
revoke all on function messaging.skip_stale_outbox(boolean) from public, anon, authenticated;

grant execute on function messaging.outbox_was_dispatched(uuid) to hms_dispatcher, service_role;
grant execute on function messaging.note_outbox_dispatched(uuid, uuid) to hms_dispatcher, service_role;
grant execute on function messaging.outbox_backlog() to hms_dispatcher, service_role;
grant execute on function messaging.skip_stale_outbox(boolean) to hms_dispatcher, service_role;
