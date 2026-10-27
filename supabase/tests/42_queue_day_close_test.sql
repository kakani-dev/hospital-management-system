-- BUG-11 / #142: close one branch's queue for a branch-local day that has ended. Today only by an
-- admin with a reason; a future day never. Waiting tokens expire; in-consultation tokens stay. Synthetic data only.
begin;

select tests.as_superuser();
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, status)
values ('e4000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000001', now() - interval '1 hour', now() - interval '40 minutes', 'booked');
set local session_replication_role = replica;
update appointment.appointments set status = 'checked_in' where id = 'e4000000-0000-4000-8000-000000000001';
insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, appointment_id, status, created_by, updated_by)
values ('f4000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001'), 801, 'aa000000-0000-4000-8000-000000000001',
        'e4000000-0000-4000-8000-000000000001', 'waiting', '0a000000-0000-4000-8000-000000000001', '0a000000-0000-4000-8000-000000000001'),
       ('f4000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001'), 802, 'aa000000-0000-4000-8000-000000000002',
        null, 'in_consultation', '0a000000-0000-4000-8000-000000000001', '0a000000-0000-4000-8000-000000000001');
set local session_replication_role = origin;

select tests.authenticate_as('lab@alpha.example');
select tests.throws_ok(
  $$select appointment.close_queue_day('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001'))$$,
  '42501', 'a role without queue.manage cannot close the day');

select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$select appointment.close_queue_day('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001') + 1)$$,
  '22023', 'a future branch-local day cannot be closed');
select tests.throws_ok(
  $$select appointment.close_queue_day('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000002'))$$,
  '42501', 'reception cannot close a branch they cannot access');
-- #142 / QUE-007: today has not ended in the branch zone, so a normal close is refused.
select tests.throws_ok(
  $$select appointment.close_queue_day('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001'))$$,
  '22023', 'reception cannot close today before it ends (old signature)');
select tests.throws_ok(
  $$select appointment.close_queue_day_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001'), null)$$,
  '22023', 'no reason: today cannot be closed early');
select tests.throws_ok(
  $$select appointment.close_queue_day_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001'), 'Zz-QA power cut')$$,
  '42501', 'reception with a reason still cannot close early (admin only)');
select tests.ok((select status from appointment.queue_entries where id = 'f4000000-0000-4000-8000-000000000001') = 'waiting', 'refused closes leave the token waiting');

select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$select appointment.close_queue_day_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001'), '   ')$$,
  '22023', 'admin: a blank reason is not a reason');
select tests.throws_ok(
  $$select appointment.close_queue_day_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001'), 'no')$$,
  '22023', 'admin: a reason shorter than 3 characters is refused');
select tests.throws_ok(
  $$select appointment.close_queue_day_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001') + 1, 'Zz-QA future')$$,
  '22023', 'admin: a future day is refused even with a reason');
select tests.ok(
  appointment.close_queue_day_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001'), 'Zz-QA emergency closure') = 1,
  'admin with a reason closes today early');
select tests.ok((select status from appointment.queue_entries where id = 'f4000000-0000-4000-8000-000000000001') = 'expired', 'the waiting token is expired');
select tests.ok((select status from appointment.appointments where id = 'e4000000-0000-4000-8000-000000000001') = 'no_show', 'its checked-in appointment is no_show');
select tests.ok((select status from appointment.queue_entries where id = 'f4000000-0000-4000-8000-000000000002') = 'in_consultation', 'a token already in consultation stays');

select tests.as_superuser();
select tests.ok(
  (select close_reason from appointment.queue_entries where id = 'f4000000-0000-4000-8000-000000000001') = 'Zz-QA emergency closure',
  'the early close keeps its reason on the expired token');

-- an earlier day (already ended) closes normally without a reason
set local session_replication_role = replica;
insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, status, created_by, updated_by)
values ('f4000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001') - 1, 803, 'aa000000-0000-4000-8000-000000000001', 'waiting',
        '0a000000-0000-4000-8000-000000000001', '0a000000-0000-4000-8000-000000000001');
set local session_replication_role = origin;
select tests.authenticate_as('reception@alpha.example');
select tests.ok(appointment.close_queue_day('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001') - 1) = 1, 'reception can close a day that has ended');
select tests.ok((select status = 'expired' and close_reason is null from appointment.queue_entries where id = 'f4000000-0000-4000-8000-000000000003'), 'a normal close stores no reason');
select tests.ok(appointment.close_queue_day('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001') - 1) = 0, 'closing the same ended day again changes nothing');

rollback;
