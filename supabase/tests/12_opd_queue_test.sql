-- Sprint 2 §3 + D11: OPD queue tokens, check_in, check_in_walk_in, set_queue_status.
-- Migration 20261010090200_opd_queue.sql. Check-in needs "today" in the BRANCH timezone, so
-- appointments are created relative to now() in that zone.
begin;

select tests.as_superuser();
create temporary table t_ctx on commit drop as
  select (now() at time zone b.timezone)::date as today, b.timezone as tz
  from identity.branches b where b.id = 'a1111111-0000-4000-8000-000000000001';
grant select on t_ctx to public;

-- Today's appointment for Kiran (aa..04) at Alpha Main, and one tomorrow for Asha (aa..01).
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
select 'e1111111-0000-4000-8000-0000000000b1', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
       'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000004',
       (today + time '00:05') at time zone tz, (today + time '00:20') at time zone tz from t_ctx;
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
select 'e1111111-0000-4000-8000-0000000000b2', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
       'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000001',
       (today + 1 + time '00:05') at time zone tz, (today + 1 + time '00:20') at time zone tz from t_ctx;
-- A doctor with access to Alpha Main, an inactive practitioner and a soft-deleted patient.
insert into auth.users (id, email, role, aud) values
  ('0a000000-0000-4000-8000-0000000000d1', 'doctor-main@alpha.example', 'authenticated', 'authenticated');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-0000000000d1', 'a1111111-0000-4000-8000-000000000001', 'doctor', 'active');
insert into appointment.practitioners (id, tenant_id, display_name, is_active)
values ('c1111111-0000-4000-8000-0000000000ff', '11111111-1111-4111-8111-111111111111', 'Dr. Retired (synthetic)', false);
insert into patient.patients (id, tenant_id, registered_branch_id, mrn, first_name, last_name, date_of_birth, deleted_at)
values ('aa000000-0000-4000-8000-0000000000de', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        'ALP-DEL', 'Deleted', 'Synthetic-Alpha', '1980-01-01', now());

-- ---------- privileges ----------
select tests.ok(
  not has_function_privilege('authenticated', 'appointment.issue_queue_token(uuid, uuid, uuid, uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'appointment.check_in_walk_in(uuid, uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'appointment.check_in(uuid, uuid, uuid, uuid, uuid)', 'execute')
  and has_function_privilege('authenticated', 'appointment.check_in_walk_in(uuid, uuid, uuid)', 'execute'),
  'issue_queue_token is internal; check_in / check_in_walk_in are authenticated-only');
select tests.ok(
  pg_get_function_result('appointment.check_in_walk_in(uuid, uuid, uuid)'::regprocedure)
    = pg_get_function_result('appointment.check_in(uuid, uuid, uuid, uuid, uuid)'::regprocedure),
  'D11: check_in_walk_in returns the same (queue_entry_id, token_no, queue_date) as check_in');
select tests.ok(
  not has_table_privilege('authenticated', 'appointment.queue_counters', 'SELECT')
  and not has_table_privilege('authenticated', 'appointment.queue_entries', 'INSERT')
  and not has_table_privilege('authenticated', 'appointment.queue_entries', 'UPDATE'),
  'queue tables: no direct writes for authenticated, counters not readable');

-- ---------- check_in with an appointment ----------
select tests.authenticate_as('reception@alpha.example');
create temporary table t1 on commit drop as
  select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
                                     'aa000000-0000-4000-8000-000000000004', 'e1111111-0000-4000-8000-0000000000b1');
select tests.ok((select token_no = 1 and queue_date = (select today from t_ctx) from t1),
  'first check-in of the branch-day gets token 1 on the branch-local date');
select tests.ok(
  (select status = 'checked_in' and checked_in_at is not null from appointment.appointments where id = 'e1111111-0000-4000-8000-0000000000b1'),
  'check_in moves the appointment booked -> checked_in');
select tests.ok(
  (select practitioner_id = 'c1111111-0000-4000-8000-000000000002' and appointment_id = 'e1111111-0000-4000-8000-0000000000b1'
   from appointment.queue_entries where id = (select queue_entry_id from t1)),
  'queue entry inherits the appointment''s practitioner');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'aa000000-0000-4000-8000-000000000004', 'e1111111-0000-4000-8000-0000000000b1')$$,
  '23505', 'checking in the same appointment twice -> 23505');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'aa000000-0000-4000-8000-000000000001', 'e1111111-0000-4000-8000-0000000000b2')$$,
  '55000', 'appointment that is not for branch-local today -> 55000');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'aa000000-0000-4000-8000-000000000002', 'e1111111-0000-4000-8000-0000000000b2')$$,
  'P0002', 'appointment belonging to another patient -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'aa000000-0000-4000-8000-000000000001', 'e1111111-0000-4000-8000-000000000001')$$,
  '55000', 'seeded 2030 appointment cannot be checked in today -> 55000');
select tests.throws_ok(
  $$select * from appointment.check_in('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001',
      'bb000000-0000-4000-8000-000000000001', 'e2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant: Alpha reception checking in a Beta appointment (Beta tenant) -> P0002 (was 42501)');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'b2222222-0000-4000-8000-000000000001',
      'aa000000-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant: Alpha tenant with a Beta branch -> P0002 (was 42501)');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'aa000000-0000-4000-8000-000000000001', 'e2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant: a Beta appointment id in an Alpha check-in -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'aa000000-0000-4000-8000-000000000001', null, 'c2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant: a Beta practitioner in an Alpha check-in -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'aa000000-0000-4000-8000-0000000000de')$$,
  'P0002', 'check_in of a soft-deleted patient -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'bb000000-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant: check_in of a Beta patient into Alpha -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
      'aa000000-0000-4000-8000-000000000003')$$,
  '42501', 'reception (Main only) checking in at Alpha East -> 42501');

-- ---------- D11: check_in_walk_in ----------
create temporary table t2 on commit drop as
  select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001');
select tests.ok((select token_no = 2 and queue_date = (select today from t_ctx) from t2),
  'walk-in shares the branch-day token sequence (token 2)');
select tests.ok(
  (select appointment_id is null and practitioner_id is null and tenant_id = '11111111-1111-4111-8111-111111111111' and status = 'waiting'
   from appointment.queue_entries where id = (select queue_entry_id from t2)),
  'walk-in entry: no appointment_id, tenant derived from the branch, status waiting');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001')$$,
  '23505', 'walk-in for a patient already waiting in this branch-day -> 23505');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000004')$$,
  '23505', 'walk-in for a patient already queued through an appointment -> 23505 (one active entry per patient)');
create temporary table t3 on commit drop as
  select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000002',
                                             'c1111111-0000-4000-8000-000000000001');
select tests.ok(
  (select t3.token_no = 3 and q.practitioner_id = 'c1111111-0000-4000-8000-000000000001'
   from t3 join appointment.queue_entries q on q.id = t3.queue_entry_id),
  'walk-in with a practitioner: token 3, practitioner recorded');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('b2222222-0000-4000-8000-000000000001', 'bb000000-0000-4000-8000-000000000001')$$,
  'P0002', 'D11 cross-tenant: another tenant''s branch -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'bb000000-0000-4000-8000-000000000002')$$,
  'P0002', 'D11 cross-tenant: another tenant''s patient -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000003',
      'c2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'D11 cross-tenant: another tenant''s practitioner -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-0000000000de')$$,
  'P0002', 'D11: soft-deleted patient -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000003',
      'c1111111-0000-4000-8000-0000000000ff')$$,
  'P0002', 'D11: inactive practitioner -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-0000000000ff', 'aa000000-0000-4000-8000-000000000003')$$,
  'P0002', 'D11: unknown branch -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000003')$$,
  '42501', 'D11: reception (Main only) at Alpha East -> 42501');
select tests.authenticate_as('outsider@example.test');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000003')$$,
  'P0002', 'D11: user with no membership -> P0002');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'aa000000-0000-4000-8000-000000000003')$$,
  'P0002', 'check_in by a user with no membership -> P0002');
select tests.authenticate_as('lab@alpha.example');
select tests.throws_ok(
  $$select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'aa000000-0000-4000-8000-000000000003')$$,
  '42501', 'check_in by a same-tenant lab technician -> 42501');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000003')$$,
  '42501', 'D11: lab technician (not front desk) -> 42501');
select tests.authenticate_as('doctor-main@alpha.example');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000003')$$,
  '42501', 'D11: doctor (not front desk) -> 42501');
select tests.authenticate_as('admin@beta.example');
select tests.throws_ok(
  $$select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000003')$$,
  'P0002', 'D11 cross-tenant: Beta admin at an Alpha branch -> P0002 (no existence leak)');
-- Beta's own sequence is independent.
create temporary table t4 on commit drop as
  select * from appointment.check_in_walk_in('b2222222-0000-4000-8000-000000000001', 'bb000000-0000-4000-8000-000000000001');
select tests.ok((select token_no = 1 from t4), 'token sequence is per tenant + branch (Beta Central starts at 1)');
select tests.authenticate_as('admin@alpha.example');
create temporary table t5 on commit drop as
  select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000003');
select tests.ok((select token_no = 1 from t5), 'token sequence is per branch (Alpha East starts at 1)');

select tests.as_superuser();
select tests.ok(
  (select last_token from appointment.queue_counters
   where branch_id = 'a1111111-0000-4000-8000-000000000001' and queue_date = (select today from t_ctx)) = 3
  and (select count(distinct token_no) = 3 and count(*) = 3 from appointment.queue_entries
       where branch_id = 'a1111111-0000-4000-8000-000000000001'),
  'counter matches the last issued token; failed attempts consumed no tokens');

-- ---------- visibility ----------
select tests.authenticate_as('reception@alpha.example');
select tests.ok((select count(*) from appointment.queue_entries) = 3, 'reception sees the 3 Alpha Main entries only');
select tests.authenticate_as('consultant@shared.example');
select tests.ok(
  not exists (select 1 from appointment.queue_entries where branch_id = 'a1111111-0000-4000-8000-000000000001')
  and exists (select 1 from appointment.queue_entries where branch_id = 'a1111111-0000-4000-8000-000000000002'),
  'queue board is branch-scoped: consultant (Alpha East) sees East, not Main');
select tests.authenticate_as('admin@beta.example');
select tests.ok(
  not exists (select 1 from appointment.queue_entries where tenant_id = '11111111-1111-4111-8111-111111111111'),
  'cross-tenant: Beta admin sees no Alpha queue entries');
select tests.authenticate_as('lab@alpha.example');
select tests.ok(not exists (select 1 from appointment.queue_entries), 'lab technician sees no queue entries');

-- ---------- set_queue_status ----------
select tests.authenticate_as('admin@beta.example');
select tests.throws_ok(
  format($$select appointment.set_queue_status(%L, 'cancelled')$$, (select queue_entry_id from t2)),
  'P0002', 'cross-tenant: Beta admin changing an Alpha queue entry -> P0002');
select tests.authenticate_as('consultant@shared.example');
select tests.throws_ok(
  format($$select appointment.set_queue_status(%L, 'in_consultation')$$, (select queue_entry_id from t2)),
  '42501', 'same-tenant doctor without access to the branch -> 42501 (was P0002)');
select tests.authenticate_as('lab@alpha.example');
select tests.throws_ok(
  format($$select appointment.set_queue_status(%L, 'cancelled')$$, (select queue_entry_id from t2)),
  '42501', 'same-tenant lab technician -> 42501 (was P0002)');
select tests.authenticate_as('outsider@example.test');
select tests.throws_ok(
  format($$select appointment.set_queue_status(%L, 'cancelled')$$, (select queue_entry_id from t2)),
  'P0002', 'user with no membership -> P0002');
select tests.throws_ok(
  $$select appointment.set_queue_status(gen_random_uuid(), 'cancelled')$$,
  'P0002', 'unknown queue entry -> P0002');
select tests.authenticate_as('doctor-main@alpha.example');
select tests.throws_ok(
  format($$select appointment.set_queue_status(%L, 'cancelled')$$, (select queue_entry_id from t2)),
  '42501', 'doctor cannot cancel a queue entry -> 42501');
select appointment.set_queue_status((select queue_entry_id from t1), 'in_consultation');
select tests.ok(
  (select q.status = 'in_consultation' and q.called_at is not null and a.status = 'in_consultation'
   from appointment.queue_entries q join appointment.appointments a on a.id = q.appointment_id
   where q.id = (select queue_entry_id from t1)),
  'doctor calls the patient: queue + appointment move to in_consultation');
select appointment.set_queue_status((select queue_entry_id from t1), 'done');
select tests.ok(
  (select q.status = 'done' and q.completed_at is not null and a.status = 'completed'
   from appointment.queue_entries q join appointment.appointments a on a.id = q.appointment_id
   where q.id = (select queue_entry_id from t1)),
  'done syncs the appointment to completed');
select tests.throws_ok(
  format($$select appointment.set_queue_status(%L, 'in_consultation')$$, (select queue_entry_id from t1)),
  '23514', 'done is terminal -> 23514');

select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  format($$select appointment.set_queue_status(%L, 'waiting')$$, (select queue_entry_id from t1)),
  '23514', 'done -> waiting -> 23514');
select tests.throws_ok(
  format($$select appointment.set_queue_status(%L, 'bogus')$$, (select queue_entry_id from t2)),
  '23514', 'unknown target status -> 23514');
select tests.throws_ok(
  format($$select appointment.set_queue_status(%L, 'done')$$, (select queue_entry_id from t2)),
  '23514', 'waiting -> done skips the consultation -> 23514');
select appointment.set_queue_status((select queue_entry_id from t2), 'cancelled');
select tests.ok(
  (select status = 'cancelled' and cancelled_at is not null from appointment.queue_entries where id = (select queue_entry_id from t2)),
  'reception cancels a waiting walk-in');
create temporary table t6 on commit drop as
  select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001');
select tests.ok((select token_no = 4 from t6), 'after cancellation the patient can walk in again (new token 4)');
create temporary table t7 on commit drop as
  select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000004');
select tests.ok((select token_no = 5 from t7), 'after done the appointment patient can walk in again (token 5)');

-- queue cancel during consultation cancels the appointment (queue_sync path)
select tests.as_superuser();
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
select 'e1111111-0000-4000-8000-0000000000b3', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
       'c1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000003',
       (today + time '00:30') at time zone tz, (today + time '00:45') at time zone tz from t_ctx;
select tests.authenticate_as('reception@alpha.example');
create temporary table t8 on commit drop as
  select * from appointment.check_in('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
                                     'aa000000-0000-4000-8000-000000000003', 'e1111111-0000-4000-8000-0000000000b3');
select appointment.set_queue_status((select queue_entry_id from t8), 'in_consultation');
select appointment.set_queue_status((select queue_entry_id from t8), 'cancelled');
select tests.ok(
  (select status = 'cancelled' from appointment.appointments where id = 'e1111111-0000-4000-8000-0000000000b3'),
  'cancelling an in-consultation queue entry cancels the appointment (queue sync)');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000002')$$,
  '55000', 'patient whose only open item is a waiting queue entry cannot be soft-deleted -> 55000');

-- ---------- outbox events ----------
select tests.as_superuser();
select tests.ok(
  (select count(*) from messaging.outbox where event_type = 'queue.token_issued' and tenant_id = '11111111-1111-4111-8111-111111111111') = 7,
  'every Alpha token (check-in and walk-in) emitted queue.token_issued');
select tests.ok(
  exists (select 1 from messaging.outbox where event_type = 'queue.token_issued'
          and aggregate_id = (select queue_entry_id from t2) and payload->>'appointment_id' is null),
  'walk-in token event carries appointment_id null');
select tests.ok(
  exists (select 1 from messaging.outbox where event_type = 'appointment.checked_in' and aggregate_id = 'e1111111-0000-4000-8000-0000000000b1'),
  'check_in emitted appointment.checked_in');

rollback;
