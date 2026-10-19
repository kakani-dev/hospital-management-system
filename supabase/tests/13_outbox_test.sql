-- Sprint 2 §4: transactional outbox (events, no PHI, dispatcher-only consumption, leases, dead-lettering).
-- Migration 20261010090300_outbox.sql. Two-session SKIP LOCKED behaviour is checked outside this suite.
begin;

-- ---------- roles and privileges ----------
select tests.ok(
  (select not rolcanlogin and not rolinherit and not rolbypassrls and not rolsuper from pg_roles where rolname = 'hms_dispatcher'),
  'hms_dispatcher is NOLOGIN NOINHERIT, no BYPASSRLS');
select tests.ok(pg_has_role('hms_svc_scheduling', 'hms_dispatcher', 'MEMBER') and not pg_has_role('hms_api', 'hms_dispatcher', 'MEMBER'),
  'only the scheduling service role may SET ROLE hms_dispatcher (B1; migration 20261011090100)');
select tests.ok(
  (select relrowsecurity from pg_class where oid = 'messaging.outbox'::regclass)
  and not has_table_privilege('authenticated', 'messaging.outbox', 'SELECT')
  and not has_table_privilege('anon', 'messaging.outbox', 'SELECT')
  and not has_table_privilege('hms_dispatcher', 'messaging.outbox', 'SELECT'),
  'outbox: RLS on, no table privileges for authenticated / anon / hms_dispatcher');
select tests.ok(
  not has_function_privilege('authenticated', 'messaging.claim_outbox(text, integer, interval)', 'execute')
  and not has_function_privilege('anon', 'messaging.claim_outbox(text, integer, interval)', 'execute')
  and not has_function_privilege('authenticated', 'messaging.enqueue(uuid, text, uuid, text, jsonb)', 'execute')
  and not has_function_privilege('hms_dispatcher', 'messaging.enqueue(uuid, text, uuid, text, jsonb)', 'execute')
  and has_function_privilege('hms_dispatcher', 'messaging.claim_outbox(text, integer, interval)', 'execute'),
  'only hms_dispatcher / service_role may claim; nobody but definer code may enqueue');

select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$select * from messaging.outbox$$, '42501', 'authenticated cannot read the outbox');
select tests.throws_ok($$select * from messaging.claim_outbox('evil')$$, '42501', 'authenticated cannot claim outbox rows');
select tests.throws_ok(
  $$select messaging.enqueue('11111111-1111-4111-8111-111111111111', 'appointment', gen_random_uuid(), 'appointment.booked', '{}')$$,
  '42501', 'authenticated cannot enqueue forged events');

-- ---------- event production ----------
select tests.as_superuser();
select tests.ok(
  (select count(*) from messaging.outbox where event_type = 'appointment.booked') = 2,
  'seeded bookings produced 2 appointment.booked events');
update messaging.outbox set status = 'done', processed_at = now();  -- start from a clean slate

select tests.authenticate_as('reception@alpha.example');
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason)
values ('e1111111-0000-4000-8000-0000000000c1', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000002',
        '2030-01-08 10:00+05:30', '2030-01-08 10:20+05:30', 'Chest pain (synthetic PHI)');
update appointment.appointments set reason = 'Edited (synthetic PHI)' where id = 'e1111111-0000-4000-8000-0000000000c1';
update appointment.appointments set starts_at = '2030-01-08 11:00+05:30', ends_at = '2030-01-08 11:20+05:30'
where id = 'e1111111-0000-4000-8000-0000000000c1';
update appointment.appointments set status = 'cancelled', cancel_reason = 'Patient moved (synthetic PHI)'
where id = 'e1111111-0000-4000-8000-0000000000c1';
select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000002');

select tests.as_superuser();
select tests.ok(
  (select array_agg(event_type order by id) from messaging.outbox where status = 'pending')
  = array['appointment.booked', 'appointment.rescheduled', 'appointment.cancelled', 'queue.token_issued'],
  'booking, reschedule, cancel and walk-in emit events in order; a reason-only edit emits none');
select tests.ok(
  not exists (
    select 1 from messaging.outbox o, jsonb_object_keys(o.payload) k
    where k in ('first_name', 'last_name', 'date_of_birth', 'phone', 'email', 'mrn', 'reason', 'cancel_reason', 'address')),
  'no event payload contains PHI fields (ids, times and statuses only)');
select tests.ok(
  not exists (select 1 from messaging.outbox where payload::text ilike '%synthetic PHI%' or payload::text ilike '%Ravi%'),
  'free-text reasons and names never reach the outbox');
select tests.ok(
  (select bool_and(tenant_id = '11111111-1111-4111-8111-111111111111' and payload->>'tenant_id' = tenant_id::text and event_id is not null)
   from messaging.outbox where status = 'pending'),
  'events carry tenant_id (column and payload) and a unique event_id');
select tests.ok(
  (select payload->>'previous_status' = 'booked' and payload->>'status' = 'cancelled'
   from messaging.outbox where event_type = 'appointment.cancelled' and status = 'pending'),
  'status events carry previous_status');

-- ---------- consumption as hms_dispatcher ----------
set local role hms_dispatcher;
select tests.throws_ok($$select * from patient.patients$$, '42501', 'hms_dispatcher cannot read patients');
select tests.throws_ok($$select * from messaging.claim_outbox('w1', 0)$$, '22023', 'batch 0 -> 22023');
select tests.throws_ok($$select * from messaging.claim_outbox(' ', 10)$$, '22023', 'blank worker id -> 22023');
select tests.throws_ok($$select * from messaging.claim_outbox('w1', 10, interval '2 hours')$$, '22023', 'lease over 1 hour -> 22023');

create temporary table c1 on commit drop as select * from messaging.claim_outbox('w1', 2);
select tests.ok(
  (select count(*) = 2 and bool_and(status = 'processing' and claimed_by = 'w1' and attempts = 1 and claimed_until > now()) from c1)
  and (select array_agg(event_type order by id) from c1) = array['appointment.booked', 'appointment.rescheduled'],
  'claim returns the oldest rows first, leased to the worker, attempts incremented');
create temporary table c2 on commit drop as select * from messaging.claim_outbox('w2', 50);
select tests.ok(
  (select count(*) = 2 and not exists (select 1 from c1 where c1.id in (select id from c2)) from c2),
  'a second worker does not get rows under an active lease');
select tests.ok((select count(*) from messaging.claim_outbox('w3', 50)) = 0, 'nothing left to claim');

select tests.throws_ok(format($$select messaging.complete_outbox(%s, 'w2')$$, (select min(id) from c1)),
  'P0002', 'completing a row leased to another worker -> P0002');
select messaging.complete_outbox((select min(id) from c1), 'w1');
select tests.throws_ok(format($$select messaging.complete_outbox(%s, 'w1')$$, (select min(id) from c1)),
  'P0002', 'completing twice -> P0002');
select messaging.fail_outbox((select max(id) from c1), 'w1', 'smtp timeout', interval '5 minutes');
select tests.ok((select count(*) from messaging.claim_outbox('w3', 50)) = 0,
  'a failed row is not re-claimable before its retry time');
select messaging.fail_outbox((select min(id) from c2), 'w2', 'transient', interval '0');
create temporary table c3 on commit drop as select * from messaging.claim_outbox('w3', 50);
select tests.ok((select count(*) = 1 and min(id) = (select min(id) from c2) and min(attempts) = 2 from c3),
  'a failed row with retry 0 is re-claimed (attempts 2)');

reset role;
select tests.ok(
  (select status = 'done' and processed_at is not null from messaging.outbox where id = (select min(id) from c1))
  and (select status = 'pending' and last_error = 'smtp timeout' and available_at > now() and claimed_by is null
       from messaging.outbox where id = (select max(id) from c1)),
  'complete -> done; fail -> pending with last_error and a future available_at');

-- lease expiry: a crashed worker's rows are re-claimed by someone else
update messaging.outbox set claimed_until = now() - interval '1 second' where id = (select max(id) from c2);
set local role hms_dispatcher;
create temporary table c4 on commit drop as select * from messaging.claim_outbox('w4', 50);
select tests.ok((select count(*) = 1 and min(id) = (select max(id) from c2) and min(attempts) = 2 from c4),
  'an expired lease is re-claimed by another worker (at-least-once)');
select tests.throws_ok(format($$select messaging.complete_outbox(%s, 'w2')$$, (select max(id) from c2)),
  'P0002', 'the original worker can no longer complete a row it lost');
reset role;

-- dead-lettering after 10 attempts
update messaging.outbox set attempts = 10 where id = (select max(id) from c2);
set local role hms_dispatcher;
select messaging.fail_outbox((select max(id) from c2), 'w4', 'permanent');
reset role;
select tests.ok((select status = 'dead' from messaging.outbox where id = (select max(id) from c2)),
  'fail on the 10th attempt -> dead');
update messaging.outbox set attempts = 10, claimed_until = now() - interval '1 second' where id = (select min(id) from c2);
set local role hms_dispatcher;
select tests.ok(
  not exists (select 1 from messaging.claim_outbox('w5', 50) c where c.id = (select min(id) from c2)),
  'an expired lease that used all attempts is not re-claimed');
reset role;
select tests.ok(
  (select status = 'dead' and last_error is not null from messaging.outbox where id = (select min(id) from c2)),
  '... it is marked dead instead');

select tests.throws_ok(
  $$update messaging.outbox set status = 'bogus' where id = (select min(id) from messaging.outbox)$$,
  '23514', 'outbox status is constrained');

rollback;
