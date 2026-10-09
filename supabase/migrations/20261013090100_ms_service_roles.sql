-- =============================================================================
-- cross-schema: approved (roles + messaging; reviewed by DB lead, 9 Oct 2026)
-- Microservices: one NOLOGIN group role per service, and a role-scoped outbox
-- (DB review B1 / S1 / S8; docs/architecture/microservices.md §4-§5). Idempotent.
--
--   service      group role (this migration)   login role (OUT OF BAND: runbook / local script, never here)
--   identity     hms_svc_identity              hms_identity_login
--   patients     hms_svc_patients              hms_patients_login
--   scheduling   hms_svc_scheduling            hms_scheduling_login
--
-- Each group role is NOLOGIN + NOINHERIT and holds NO table privileges. A service reaches data only via
-- SET LOCAL ROLE authenticated + request.jwt.claims per transaction (RlsTransactionInterceptor), so every
-- RLS policy, auth.uid() and the identity.* helpers keep working unchanged. Phase 6 hardening then becomes
-- grant changes on these roles only.
--
-- Outbox (B1): hms_api (legacy all-in-one login) LOSES hms_dispatcher. Only hms_svc_scheduling (the only
-- producer/consumer today) may SET ROLE hms_dispatcher, and claim/complete/fail only touch rows whose
-- source_service belongs to the CALLING LOGIN's service role (derived from session_user, never from an
-- argument). source_service is set by the database from the aggregate type, never by the caller.
--
-- Hosted (needs approval; docs/architecture/microservices.md §9): after this migration
--   create role hms_<svc>_login login noinherit password '<secret>'; grant hms_svc_<svc> to hms_<svc>_login;
-- and keep Outbox:Dispatcher:Enabled=false on the legacy host (it can no longer dispatch).
-- =============================================================================
do $$
declare
  r text;
begin
  foreach r in array array['hms_svc_identity', 'hms_svc_patients', 'hms_svc_scheduling'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin noinherit', r);
    end if;
    execute format('grant authenticated to %I', r);
    execute format('grant anon to %I', r);
  end loop;
end
$$;

comment on role hms_svc_identity is
  'HMS identity service: no direct privileges; SET ROLE authenticated/anon per transaction so RLS applies.';
comment on role hms_svc_patients is
  'HMS patients service: no direct privileges; SET ROLE authenticated/anon per transaction so RLS applies.';
comment on role hms_svc_scheduling is
  'HMS scheduling service: no direct privileges; SET ROLE authenticated/anon per transaction (RLS), hms_dispatcher for its own outbox rows.';

-- ---------------------------------------------------------------- dispatcher ----
revoke hms_dispatcher from hms_api;
grant hms_dispatcher to hms_svc_scheduling;

-- ---------------------------------------------------------------- source_service ----
alter table messaging.outbox add column if not exists source_service text;
update messaging.outbox set source_service = 'scheduling'
 where source_service is null and aggregate_type in ('appointment', 'queue_entry');
alter table messaging.outbox alter column source_service set not null;
alter table messaging.outbox drop constraint if exists outbox_source_service_valid;
alter table messaging.outbox add constraint outbox_source_service_valid
  check (source_service in ('identity', 'patients', 'scheduling'));
create index if not exists outbox_source_claimable_idx
  on messaging.outbox (source_service, status, available_at, id) where status in ('pending', 'processing');
comment on column messaging.outbox.source_service is
  'Producing service; set by messaging.set_outbox_source() from aggregate_type, never by the caller.';

-- The owning service of each aggregate type. New producers add their types here (same migration that
-- widens outbox_aggregate_type_valid).
create or replace function messaging.set_outbox_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.source_service := case new.aggregate_type
    when 'appointment' then 'scheduling'
    when 'queue_entry' then 'scheduling'
  end;
  if new.source_service is null then
    raise exception 'no owning service for aggregate type %', new.aggregate_type using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function messaging.set_outbox_source() from public;

drop trigger if exists outbox_set_source on messaging.outbox;
create trigger outbox_set_source before insert or update of aggregate_type, source_service on messaging.outbox
  for each row execute function messaging.set_outbox_source();

-- Which producers' rows may the CURRENT LOGIN consume? Derived from session_user's service role.
-- service_role (Supabase admin) and superusers see all; anything else sees nothing.
create or replace function messaging.caller_sources()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (select 1 from pg_catalog.pg_roles r where r.rolname = session_user and r.rolsuper)
      or pg_catalog.pg_has_role(session_user, 'service_role', 'MEMBER')
      then array['identity', 'patients', 'scheduling']
    else array_remove(array[
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_identity', 'MEMBER') then 'identity' end,
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_patients', 'MEMBER') then 'patients' end,
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_scheduling', 'MEMBER') then 'scheduling' end], null)
  end
$$;
revoke all on function messaging.caller_sources() from public, anon, authenticated;
grant execute on function messaging.caller_sources() to hms_dispatcher, service_role;

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

  update messaging.outbox o
     set status = 'dead', claimed_by = null, claimed_until = null,
         last_error = coalesce(o.last_error, 'lease expired after max attempts')
   where o.status = 'processing' and o.claimed_until < now() and o.attempts >= 10
     and o.source_service = any (v_sources);

  return query
  with c as (
    select o.id
    from messaging.outbox o
    where o.source_service = any (v_sources)
      and ((o.status = 'pending' and o.available_at <= now())
        or (o.status = 'processing' and o.claimed_until < now()))
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
   where o.id = p_id and o.status = 'processing' and o.claimed_by = p_worker
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
         available_at = case when o.attempts >= 10 then o.available_at else now() + p_retry_in end,
         last_error = left(coalesce(p_error, ''), 2000),
         claimed_by = null,
         claimed_until = null
   where o.id = p_id and o.status = 'processing' and o.claimed_by = p_worker
     and o.source_service = any (messaging.caller_sources());
  if not found then
    raise exception 'outbox row not claimed by this worker' using errcode = 'P0002';
  end if;
end;
$$;
-- CREATE OR REPLACE keeps the existing grants (hms_dispatcher, service_role) on claim/complete/fail.
