-- Visit-length aware slots and the local-midnight window end (20261027090000, #98). Synthetic data; rolls back.
begin;

select tests.authenticate_as('admin@alpha.example');
insert into appointment.practitioners (id, tenant_id, display_name)
values ('c1111111-0000-4000-8000-000000000048', '11111111-1111-4111-8111-111111111111', 'Dr. Late (synthetic)');
insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id)
values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000048', 'a1111111-0000-4000-8000-000000000001');
-- Wednesdays 22:00-24:00 IST, 15-minute slots; 2030-06-05 is a Wednesday.
insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000048',
        'a1111111-0000-4000-8000-000000000001', 3, '22:00', '24:00', 15, (date '2030-01-01' + tests.fwd_days()));
insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000048',
        'aa000000-0000-4000-8000-000000000001', (timestamptz '2030-06-05 22:30+05:30' + tests.fwd()), (timestamptz '2030-06-05 22:45+05:30' + tests.fwd()));

create temp table s48 as
select (slot_start at time zone 'Asia/Kolkata')::time as l_start, slot_end - slot_start as len, 'slot' as kind
from appointment.available_slots_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
       (date '2030-06-05' + tests.fwd_days()), (date '2030-06-05' + tests.fwd_days()), 'c1111111-0000-4000-8000-000000000048', null)
union all
select (slot_start at time zone 'Asia/Kolkata')::time, slot_end - slot_start, 'v30'
from appointment.available_slots_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
       (date '2030-06-05' + tests.fwd_days()), (date '2030-06-05' + tests.fwd_days()), 'c1111111-0000-4000-8000-000000000048', 30);

select tests.ok(
  (select array_agg(l_start order by l_start) from s48 where kind = 'slot')
    = array['22:00','22:15','22:45','23:00','23:15','23:30','23:45']::time[]
  and (select bool_and(len = interval '15 minutes') from s48 where kind = 'slot'),
  'no visit length: one slot each, booked 22:30 excluded, the last slot ends at midnight');
select tests.ok(
  (select array_agg(l_start order by l_start) from s48 where kind = 'v30')
    = array['22:00','22:45','23:00','23:15','23:30']::time[]
  and (select bool_and(len = interval '30 minutes') from s48 where kind = 'v30'),
  '30-minute visit: no start that overlaps the 22:30 booking or runs past 24:00; slot_end = start + 30');
select tests.ok(
  (select count(*) from appointment.available_slots_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
       (date '2030-06-05' + tests.fwd_days()), (date '2030-06-05' + tests.fwd_days()), 'c1111111-0000-4000-8000-000000000048', 180)) = 0,
  'a visit longer than the window offers nothing');
select tests.ok(
  (select array_agg(slot_start order by slot_start) from appointment.available_slots('11111111-1111-4111-8111-111111111111',
       'a1111111-0000-4000-8000-000000000001', (date '2030-06-05' + tests.fwd_days()), (date '2030-06-05' + tests.fwd_days()), 'c1111111-0000-4000-8000-000000000048'))
  = (select array_agg(slot_start order by slot_start) from appointment.available_slots_v2('11111111-1111-4111-8111-111111111111',
       'a1111111-0000-4000-8000-000000000001', (date '2030-06-05' + tests.fwd_days()), (date '2030-06-05' + tests.fwd_days()), 'c1111111-0000-4000-8000-000000000048', null)),
  'available_slots (old signature) keeps returning one-slot starts');
select tests.throws_ok(
  $$select * from appointment.available_slots_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      (date '2030-06-05' + tests.fwd_days()), (date '2030-06-05' + tests.fwd_days()), null, 4)$$,
  '22023', 'a visit length under 5 minutes is rejected');

-- #98: a visit that ends exactly at local midnight is inside a window ending at 24:00.
select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
  'c1111111-0000-4000-8000-000000000048', (timestamptz '2030-06-05 23:45+05:30' + tests.fwd()), (timestamptz '2030-06-06 00:00+05:30' + tests.fwd()), false);
select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
  'c1111111-0000-4000-8000-000000000048', (timestamptz '2030-06-05 23:30+05:30' + tests.fwd()), (timestamptz '2030-06-06 00:00+05:30' + tests.fwd()), false);
select tests.ok(true, '#98: 23:45-00:00 and 23:30-00:00 IST are bookable in a 22:00-24:00 window');
select tests.throws_ok(
  $$select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'c1111111-0000-4000-8000-000000000048', (timestamptz '2030-06-05 23:45+05:30' + tests.fwd()), (timestamptz '2030-06-06 00:15+05:30' + tests.fwd()), false)$$,
  '22023', 'a visit running past midnight is still outside working hours');
select tests.throws_ok(
  $$select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'c1111111-0000-4000-8000-000000000048', (timestamptz '2030-06-05 21:45+05:30' + tests.fwd()), (timestamptz '2030-06-05 22:15+05:30' + tests.fwd()), false)$$,
  '22023', 'a visit starting before the window is still outside working hours');

-- Same rule on a date override (2030-06-12, Wednesday) ending at 24:00.
insert into appointment.schedule_overrides (tenant_id, practitioner_id, branch_id, override_date, is_leave, start_time, end_time, slot_minutes)
values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000048',
        'a1111111-0000-4000-8000-000000000001', (date '2030-06-12' + tests.fwd_days()), false, '23:00', '24:00', 15);
select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
  'c1111111-0000-4000-8000-000000000048', (timestamptz '2030-06-12 23:45+05:30' + tests.fwd()), (timestamptz '2030-06-13 00:00+05:30' + tests.fwd()), false);
select tests.ok(true, 'an override ending at 24:00 also accepts a visit ending at midnight');
select tests.throws_ok(
  $$select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      'c1111111-0000-4000-8000-000000000048', (timestamptz '2030-06-12 22:00+05:30' + tests.fwd()), (timestamptz '2030-06-12 22:30+05:30' + tests.fwd()), false)$$,
  '22023', 'the override replaces the weekly 22:00 start for that day');
select tests.ok(
  (select array_agg((slot_start at time zone 'Asia/Kolkata')::time order by slot_start)
     from appointment.available_slots_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
       (date '2030-06-12' + tests.fwd_days()), (date '2030-06-12' + tests.fwd_days()), 'c1111111-0000-4000-8000-000000000048', 30))
  = array['23:00','23:15','23:30']::time[],
  'override day: 30-minute visits start no later than 23:30');

select tests.authenticate_as('admin@beta.example');
select tests.throws_ok(
  $$select * from appointment.available_slots_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
      (date '2030-06-05' + tests.fwd_days()), (date '2030-06-05' + tests.fwd_days()), null, 30)$$,
  'P0002', 'cross-tenant: Beta cannot list Alpha slots');

rollback;
