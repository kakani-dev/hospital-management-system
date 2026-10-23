-- Microservices: one database role per service (migration 20261013090100_ms_service_roles.sql, DB review B1/S1/S8).
begin;

select tests.as_superuser();

select tests.ok(
  (select bool_and(not rolcanlogin and not rolinherit and not rolsuper and not rolbypassrls and not rolcreaterole)
     from pg_roles where rolname in ('hms_svc_identity', 'hms_svc_patients', 'hms_svc_scheduling'))
  and (select count(*) from pg_roles where rolname in ('hms_svc_identity', 'hms_svc_patients', 'hms_svc_scheduling')) = 3,
  'service group roles exist and are NOLOGIN, NOINHERIT, not superuser, no BYPASSRLS');

select tests.ok(
  not pg_has_role('hms_svc_identity', 'authenticated', 'SET')
  and not pg_has_role('hms_svc_patients', 'authenticated', 'SET')
  and not pg_has_role('hms_svc_scheduling', 'authenticated', 'SET'),
  'service roles cannot SET ROLE authenticated (ADR 0002: the session role is hms_svc_*)');

select tests.ok(
  not pg_has_role('hms_svc_identity', 'authenticated', 'USAGE')
  and not pg_has_role('hms_svc_patients', 'authenticated', 'USAGE')
  and not pg_has_role('hms_svc_scheduling', 'authenticated', 'USAGE'),
  'service roles do not INHERIT authenticated privileges (fail closed outside an RLS transaction)');

select tests.ok(
  pg_has_role('hms_svc_scheduling', 'hms_dispatcher', 'SET')
  and not pg_has_role('hms_svc_identity', 'hms_dispatcher', 'SET')
  and not pg_has_role('hms_svc_patients', 'hms_dispatcher', 'SET'),
  'only the scheduling service can switch to hms_dispatcher (outbox owner)');

select tests.ok(
  not exists (select 1 from pg_class c join pg_roles r on r.oid = c.relowner
              where r.rolname in ('hms_svc_identity', 'hms_svc_patients', 'hms_svc_scheduling'))
  and not has_table_privilege('hms_svc_identity', 'patient.patients', 'select')
  and not has_table_privilege('hms_svc_patients', 'appointment.appointments', 'select')
  and not has_table_privilege('hms_svc_scheduling', 'identity.memberships', 'select'),
  'service roles own nothing and cannot select another service''s tables');

select tests.ok(
  (select bool_and(rolcanlogin and not rolinherit)
     from pg_roles where rolname in ('hms_identity_login', 'hms_patients_login', 'hms_scheduling_login'))
  and pg_has_role('hms_identity_login', 'hms_svc_identity', 'SET')
  and pg_has_role('hms_patients_login', 'hms_svc_patients', 'SET')
  and pg_has_role('hms_scheduling_login', 'hms_svc_scheduling', 'SET'),
  'local login roles are NOINHERIT members of their own service role');

select tests.ok(
  not pg_has_role('hms_patients_login', 'hms_svc_identity', 'MEMBER')
  and not pg_has_role('hms_identity_login', 'hms_svc_scheduling', 'MEMBER')
  and not pg_has_role('hms_patients_login', 'hms_dispatcher', 'MEMBER'),
  'a service login cannot assume another service''s role or the dispatcher');

select tests.ok(
  not pg_has_role('hms_api', 'hms_dispatcher', 'MEMBER') and not pg_has_role('hms_api_login', 'hms_dispatcher', 'MEMBER'),
  'B1: the legacy hms_api / hms_api_login can no longer reach hms_dispatcher');

select tests.ok(
  pg_has_role('hms_svc_identity', 'hms_mailer', 'SET')
  and pg_has_role('hms_identity_login', 'hms_mailer', 'SET')
  and not pg_has_role('hms_svc_scheduling', 'hms_mailer', 'SET')
  and not pg_has_role('hms_svc_patients', 'hms_mailer', 'SET')
  and not pg_has_role('hms_api', 'hms_mailer', 'MEMBER')
  and not pg_has_role('hms_api_login', 'hms_mailer', 'MEMBER'),
  'only the identity service can switch to hms_mailer; the legacy login cannot (B1)');

-- ---------- outbox source_service (set by the DB, never by the caller) ----------
select tests.ok(
  (select attnotnull from pg_attribute where attrelid = 'messaging.outbox'::regclass and attname = 'source_service'),
  'outbox.source_service exists and is NOT NULL');
insert into messaging.outbox (tenant_id, aggregate_type, aggregate_id, event_type, payload, source_service)
values ('11111111-1111-4111-8111-111111111111', 'appointment', gen_random_uuid(), 'test.forged', '{}', 'patients');
select tests.ok(
  (select source_service from messaging.outbox where event_type = 'test.forged') = 'scheduling',
  'a caller-supplied source_service is overwritten from the aggregate type');
update messaging.outbox set source_service = 'identity' where event_type = 'test.forged';
select tests.ok(
  (select source_service from messaging.outbox where event_type = 'test.forged') = 'scheduling',
  'source_service cannot be changed by an update either');

-- ---------- role-scoped consumption: only the scheduling login consumes scheduling events ----------
update messaging.outbox set status = 'done' where status in ('pending', 'processing');
insert into messaging.outbox (tenant_id, aggregate_type, aggregate_id, event_type, payload)
values ('11111111-1111-4111-8111-111111111111', 'queue_entry', gen_random_uuid(), 'test.scoped', '{}');

set local session authorization hms_patients_login;
select tests.throws_ok($$set local role hms_dispatcher$$, '42501',
  'patients login cannot SET ROLE hms_dispatcher');
reset session authorization;

set local session authorization hms_api_login;
select tests.throws_ok($$set local role hms_dispatcher$$, '42501',
  'legacy hms_api_login cannot SET ROLE hms_dispatcher any more');
reset session authorization;

set local session authorization hms_scheduling_login;
set local role hms_dispatcher;
select tests.ok(
  messaging.caller_sources() = array['scheduling'],
  'scheduling login (as hms_dispatcher) consumes exactly the scheduling source');
select tests.ok(
  (select count(*) from messaging.claim_outbox('t-sched', 50, '30 seconds') c where c.event_type = 'test.scoped') = 1,
  'scheduling login claims its own scheduling event');
reset role;
reset session authorization;

rollback;
