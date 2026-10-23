-- cross-schema: approved (messaging.outbox aggregate billing → source_service billing.
-- Billing publishes; it is not granted hms_dispatcher.)
set local lock_timeout = '5s';
set local statement_timeout = '30s';

alter table messaging.outbox drop constraint outbox_aggregate_type_valid;
alter table messaging.outbox add constraint outbox_aggregate_type_valid
  check (aggregate_type in ('appointment', 'queue_entry', 'tenant', 'email_message', 'patient', 'billing'));

alter table messaging.outbox drop constraint outbox_source_service_valid;
alter table messaging.outbox add constraint outbox_source_service_valid
  check (source_service in ('identity', 'patients', 'scheduling', 'billing'));

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
    when 'email_message' then 'identity'
    when 'patient' then 'patients'
    when 'billing' then 'billing'
  end;
  if new.source_service is null then
    raise exception 'no owning service for aggregate type %', new.aggregate_type using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function messaging.set_outbox_source() from public;

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
      then array['identity', 'patients', 'scheduling', 'billing']
    else array_remove(array[
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_identity', 'MEMBER') then 'identity' end,
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_patients', 'MEMBER') then 'patients' end,
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_scheduling', 'MEMBER') then 'scheduling' end,
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_billing', 'MEMBER') then 'billing' end], null)
  end
$$;
revoke all on function messaging.caller_sources() from public, anon, authenticated;
grant execute on function messaging.caller_sources() to hms_dispatcher, hms_mailer, service_role;
