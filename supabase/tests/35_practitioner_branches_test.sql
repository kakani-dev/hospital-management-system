-- A practitioner works at many branches. Hours and bookings cannot overlap in absolute time.
begin;

select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  exists (select 1 from appointment.practitioner_branches
           where practitioner_id = 'c1111111-0000-4000-8000-000000000002'
             and branch_id = 'a1111111-0000-4000-8000-000000000001' and is_active and not is_deleted)
  and exists (select 1 from appointment.practitioner_branches
           where practitioner_id = 'c1111111-0000-4000-8000-000000000001'
             and branch_id = 'a1111111-0000-4000-8000-000000000002' and is_active and not is_deleted),
  'existing schedule rows became active memberships');

insert into appointment.practitioners (id, tenant_id, display_name)
values ('c1111111-0000-4000-8000-000000000035', '11111111-1111-4111-8111-111111111111', 'Dr. Multi (synthetic)');

select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
    values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
            'a1111111-0000-4000-8000-000000000001', 1, '09:00', '13:00', 60, '2026-01-01')$$,
  '22023', 'a schedule needs an active membership at that branch');

insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id) values
  ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035', 'a1111111-0000-4000-8000-000000000001'),
  ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035', 'a1111111-0000-4000-8000-000000000002');
select tests.ok((select count(*) from appointment.practitioner_branches) = 4,
  'Alpha admin sees the seeded memberships plus the two new ones');

insert into appointment.schedules (id, tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
values ('d1111111-0000-4000-8000-000000000351', '11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
        'a1111111-0000-4000-8000-000000000001', 1, '09:00', '13:00', 60, '2026-01-01');

select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
    values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
            'a1111111-0000-4000-8000-000000000002', 1, '10:00', '12:00', 60, '2026-01-01')$$,
  '23P01', 'the same Monday morning at another branch overlaps in absolute time');

insert into appointment.schedules (id, tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
values ('d1111111-0000-4000-8000-000000000353', '11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
        'a1111111-0000-4000-8000-000000000002', 1, '13:00', '17:00', 60, '2026-01-01');
select tests.ok(true, '13:00 at East after 09:00-13:00 at Main is back-to-back when the buffer is 0');
update appointment.schedules set is_active = false where id = 'd1111111-0000-4000-8000-000000000353';

-- Sunday 22:30-23:30 in New York (EST, January) is Monday 09:00-10:00 in Kolkata.
select tests.as_superuser();
update identity.branches set timezone_override = 'America/New_York' where id = 'a1111111-0000-4000-8000-000000000002';
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
    values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
            'a1111111-0000-4000-8000-000000000002', 7, '22:30', '23:30', 30, '2026-01-01')$$,
  '23P01', 'a Sunday evening in New York overlaps Monday morning in Kolkata');
insert into appointment.schedules (id, tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
values ('d1111111-0000-4000-8000-000000000354', '11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
        'a1111111-0000-4000-8000-000000000002', 1, '09:00', '13:00', 60, '2026-01-01');
select tests.ok(true, 'Monday 09:00-13:00 in New York starts at 19:30 in Kolkata, after Main closes');
update appointment.schedules set is_active = false where id = 'd1111111-0000-4000-8000-000000000354';
select tests.as_superuser();
update identity.branches set timezone = 'Asia/Kolkata' where id = 'a1111111-0000-4000-8000-000000000002';
select tests.authenticate_as('admin@alpha.example');

insert into appointment.tenant_settings (tenant_id, travel_buffer_minutes)
values ('11111111-1111-4111-8111-111111111111', 30)
on conflict (tenant_id) do update set travel_buffer_minutes = excluded.travel_buffer_minutes;
select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
    values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
            'a1111111-0000-4000-8000-000000000002', 1, '13:00', '17:00', 60, '2026-01-01')$$,
  '23P01', 'a 30 minute travel buffer rejects a visit that starts when the other branch ends');
update appointment.tenant_settings set travel_buffer_minutes = 0 where tenant_id = '11111111-1111-4111-8111-111111111111';

insert into appointment.schedules (id, tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
values ('d1111111-0000-4000-8000-000000000352', '11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
        'a1111111-0000-4000-8000-000000000002', 1, '17:00', '20:00', 60, '2026-01-01');
select tests.ok(true, 'East evening hours are stored once the buffer is back to 0');

select tests.throws_ok(
  $$insert into appointment.schedule_overrides (tenant_id, practitioner_id, branch_id, override_date, is_leave, start_time, end_time, slot_minutes)
    values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
            'a1111111-0000-4000-8000-000000000002', '2030-06-03', false, '10:00', '11:00', 15)$$,
  '23P01', 'an East hour override during Main hours is rejected');
insert into appointment.schedule_overrides (tenant_id, practitioner_id, branch_id, override_date, is_leave, start_time, end_time, slot_minutes)
values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
        'a1111111-0000-4000-8000-000000000001', '2030-06-17', false, '15:00', '16:00', 15);
select tests.ok(true, 'a same-branch hour override replaces that day and does not clash with the weekly template');

insert into appointment.schedule_overrides (tenant_id, practitioner_id, branch_id, override_date, is_leave)
values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
        'a1111111-0000-4000-8000-000000000001', '2030-06-10', true);
select tests.ok(
  (select count(*) from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
                                                    '2030-06-10', '2030-06-10', 'c1111111-0000-4000-8000-000000000035')) = 0,
  'leave removes that branch''s slots for the day');
select tests.ok(
  (select count(*) from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
                                                    '2030-06-10', '2030-06-10', 'c1111111-0000-4000-8000-000000000035')) = 3,
  'leave at Main leaves the East evening slots');

select tests.ok(
  (select count(*) = 4
     and bool_and((slot_start at time zone 'Asia/Kolkata')::time >= '09:00'
              and (slot_end at time zone 'Asia/Kolkata')::time <= '13:00')
   from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
                                    '2030-06-03', '2030-06-03', 'c1111111-0000-4000-8000-000000000035')),
  'Main offers only the Monday morning window');
select tests.ok(
  (select count(*) = 3
     and bool_and((slot_start at time zone 'Asia/Kolkata')::time >= '17:00'
              and (slot_end at time zone 'Asia/Kolkata')::time <= '20:00')
   from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
                                    '2030-06-03', '2030-06-03', 'c1111111-0000-4000-8000-000000000035')),
  'East offers only the Monday evening window');

select appointment.assert_bookable_window_v2(
  '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000035',
  '2030-06-03 17:00+05:30', '2030-06-03 18:00+05:30', false);
select tests.ok(true, 'booking at East is checked against East hours');
select tests.throws_ok(
  $$select appointment.assert_bookable_window_v2(
      '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000035',
      '2030-06-03 10:00+05:30', '2030-06-03 11:00+05:30', false)$$,
  '22023', 'East morning is outside East hours even though Main is open');
select appointment.assert_bookable_window_v2(
  '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000035',
  '2030-06-03 12:00+05:30', '2030-06-03 12:15+05:30', true);
select tests.ok(true, 'an hours override waives this branch''s window');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, hours_override)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000035',
            'aa000000-0000-4000-8000-000000000001', '2030-06-03 12:00+05:30', '2030-06-03 12:15+05:30', true)$$,
  '23P01', 'the override still cannot land inside another branch''s hours');

insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
values ('e1111111-0000-4000-8000-000000000351', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        'c1111111-0000-4000-8000-000000000035', 'aa000000-0000-4000-8000-000000000001',
        '2030-06-03 09:00+05:30', '2030-06-03 10:00+05:30'),
       ('e1111111-0000-4000-8000-000000000352', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
        'c1111111-0000-4000-8000-000000000035', 'aa000000-0000-4000-8000-000000000002',
        '2030-06-03 17:00+05:30', '2030-06-03 18:00+05:30');
select tests.ok((select count(*) from appointment.appointments where practitioner_id = 'c1111111-0000-4000-8000-000000000035') = 2,
  'the same doctor can be booked at both branches when the times do not overlap');

update appointment.practitioner_branches set is_active = false
 where practitioner_id = 'c1111111-0000-4000-8000-000000000035' and branch_id = 'a1111111-0000-4000-8000-000000000002';
select tests.throws_ok(
  $$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
    values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035',
            'a1111111-0000-4000-8000-000000000002', 5, '17:00', '18:00', 60, '2026-01-01')$$,
  '22023', 'an inactive membership cannot take new hours');

select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id)
    values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035', 'a1111111-0000-4000-8000-000000000001')$$,
  '42501', 'reception cannot add a membership');

select tests.authenticate_as('admin@beta.example');
select tests.ok((select count(*) from appointment.practitioner_branches) = 1, 'cross-tenant: Beta sees only its own membership');
select tests.throws_ok(
  $$insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id)
    values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000035', 'a1111111-0000-4000-8000-000000000001')$$,
  '42501', 'cross-tenant: Beta cannot insert an Alpha membership');
select tests.ok(
  tests.affected_rows($$update appointment.practitioner_branches set is_active = false where practitioner_id = 'c1111111-0000-4000-8000-000000000035'$$) = 0,
  'cross-tenant: Beta cannot update an Alpha membership');

rollback;
