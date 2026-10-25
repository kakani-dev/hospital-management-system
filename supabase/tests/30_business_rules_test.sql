-- Business rules 2026-10-20 (migration 20261020140000). Synthetic data only.
begin;

-- ============================================ 1. working hours + admin override ==
-- 2030-01-07 is a Monday; Dr. Alpha General works Mon 10:00-14:00 at Alpha Main.
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  (select count(*) from (select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
     'c1111111-0000-4000-8000-000000000002', '2030-01-07 10:20+05:30', '2030-01-07 10:40+05:30', false)) x) = 1,
  'inside working hours is bookable');
select tests.throws_ok($$select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
  'c1111111-0000-4000-8000-000000000002', '2030-01-07 15:00+05:30', '2030-01-07 15:20+05:30', false)$$,
  '22023', 'outside working hours is rejected');
select tests.throws_ok($$select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
  'c1111111-0000-4000-8000-000000000002', '2030-01-07 13:50+05:30', '2030-01-07 14:10+05:30', false)$$,
  '22023', 'a booking running past the end of the shift is rejected');
select tests.throws_ok($$select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
  'c1111111-0000-4000-8000-000000000002', '2030-01-09 10:00+05:30', '2030-01-09 10:20+05:30', false)$$,
  '22023', 'a weekday without a schedule is rejected');
select tests.throws_ok($$select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
  'c1111111-0000-4000-8000-000000000002', '2030-01-07 15:00+05:30', '2030-01-07 15:20+05:30', true)$$,
  '42501', 'reception cannot override working hours');
select tests.throws_ok($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, hours_override)
  values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
          'aa000000-0000-4000-8000-000000000002', '2030-01-07 16:00+05:30', '2030-01-07 16:20+05:30', true)$$,
  '42501', 'reception cannot store an override flag directly');
select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  (select count(*) from (select appointment.assert_bookable_window_v2('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
     'c1111111-0000-4000-8000-000000000002', '2030-01-07 15:00+05:30', '2030-01-07 15:20+05:30', true)) x) = 1,
  'an admin may override working hours');
select tests.throws_ok($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, hours_override)
  values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
          'aa000000-0000-4000-8000-000000000002', '2030-01-07 16:30+05:30', '2030-01-07 16:50+05:30', true)$$,
  '22023', 'an override without a reason is rejected');
select tests.throws_ok($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, hours_override, reason)
  values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
          'aa000000-0000-4000-8000-000000000002', '2030-01-07 16:30+05:30', '2030-01-07 16:50+05:30', true, '   ')$$,
  '22023', 'a blank override reason is rejected');
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, hours_override, reason)
values ('e3000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000002', '2030-01-07 15:00+05:30', '2030-01-07 15:20+05:30', true,
        'Emergency add-on (synthetic)');
select tests.as_superuser();
select tests.ok(exists (select 1 from audit.audit_log where table_name = 'appointments' and record_id = 'e3000000-0000-4000-8000-000000000001'
                          and (new_data ->> 'hours_override')::boolean and changed_by = '0a000000-0000-4000-8000-000000000001'),
  'the override is in the audit log with the admin as actor');
select tests.throws_ok($$update appointment.appointments set hours_override = false where id = 'e3000000-0000-4000-8000-000000000001'$$,
  '22023', 'an override flag cannot be cleared');

-- ============================================ 2. booking permissions ==
select tests.ok(identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'appointments.book') is not null, 'helper callable');
select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e300000-0000-4000-8000-000000000001', 'nurse-br@alpha.example', 'authenticated', 'authenticated');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0e300000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000001', 'nurse', 'active');
select tests.authenticate_as('nurse-br@alpha.example');
select tests.ok(tests.affected_rows($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
  values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
          'aa000000-0000-4000-8000-000000000002', '2030-01-07 11:00+05:30', '2030-01-07 11:20+05:30')$$) = 1, 'a nurse can book');

select tests.authenticate_as('doctor@beta.example');
select tests.throws_ok($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
  values ('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'c2222222-0000-4000-8000-000000000001',
          'bb000000-0000-4000-8000-000000000001', '2030-01-14 09:00+05:30', '2030-01-14 09:15+05:30')$$,
  '42501', 'a doctor cannot book a fresh appointment');
select tests.ok(tests.affected_rows($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, parent_appointment_id)
  values ('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'c2222222-0000-4000-8000-000000000001',
          'bb000000-0000-4000-8000-000000000001', '2030-01-14 09:00+05:30', '2030-01-14 09:15+05:30', 'e2222222-0000-4000-8000-000000000001')$$) = 1,
  'a doctor can book a follow-up of an earlier visit');

-- ============================================ 3. follow-up link ==
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, parent_appointment_id)
  values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
          'aa000000-0000-4000-8000-000000000002', '2030-01-14 10:00+05:30', '2030-01-14 10:20+05:30', 'e1111111-0000-4000-8000-000000000001')$$,
  '22023', 'a follow-up for a different patient is rejected');
select tests.throws_ok($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, parent_appointment_id)
  values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
          'aa000000-0000-4000-8000-000000000001', '2030-01-14 10:00+05:30', '2030-01-14 10:20+05:30', 'e2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'a parent from another tenant looks unknown');
select tests.ok(tests.affected_rows($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, parent_appointment_id)
  values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
          'aa000000-0000-4000-8000-000000000001', '2030-01-14 10:00+05:30', '2030-01-14 10:20+05:30', 'e1111111-0000-4000-8000-000000000001')$$) = 1,
  'a follow-up for the same patient links to the earlier visit');

-- ============================================ 4. end of day ==
select tests.as_superuser();
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, status)
  select 'e3000000-0000-4000-8000-000000000009', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
         'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000004', now() - interval '2 days', now() - interval '2 days' + interval '20 minutes', 'booked';
set local session_replication_role = replica; -- synthetic history: bypass triggers for the fixture rows only
update appointment.appointments set status = 'checked_in' where id = 'e3000000-0000-4000-8000-000000000009';
insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, appointment_id, status, created_by, updated_by)
values ('f3000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001') - 1, 901, 'aa000000-0000-4000-8000-000000000004', 'e3000000-0000-4000-8000-000000000009', 'waiting', '0a000000-0000-4000-8000-000000000001', '0a000000-0000-4000-8000-000000000001'),
       ('f3000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001'), 902, 'aa000000-0000-4000-8000-000000000003', null, 'waiting', '0a000000-0000-4000-8000-000000000001', '0a000000-0000-4000-8000-000000000001');
set local session_replication_role = origin;
select tests.ok(appointment.close_stale_queues() >= 1, 'end-of-day close runs');
select tests.ok((select status from appointment.queue_entries where id = 'f3000000-0000-4000-8000-000000000001') = 'no_show', 'yesterday''s waiting entry is no_show');
select tests.ok((select status from appointment.appointments where id = 'e3000000-0000-4000-8000-000000000009') = 'no_show', 'its appointment is no_show');
select tests.ok((select status from appointment.queue_entries where id = 'f3000000-0000-4000-8000-000000000002') = 'waiting', 'today''s entry is untouched');
select tests.ok(appointment.close_stale_queues() = 0, 'idempotent');
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok($$select appointment.close_stale_queues()$$, '42501', 'clients cannot run the close');

-- ============================================ 5. unique branch names ==
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$insert into identity.branches (tenant_id, code, name) values ('11111111-1111-4111-8111-111111111111', 'dup', '  alpha MAIN campus ')$$,
  '23505', 'branch names are unique per tenant (case-insensitive, trimmed)');
select tests.authenticate_as('admin@beta.example');
select tests.ok(tests.affected_rows($$insert into identity.branches (tenant_id, code, name) values ('22222222-2222-4222-8222-222222222222', 'amc', 'Alpha Main Campus')$$) = 1,
  'another tenant may reuse the name');

-- ============================================ 6. last admin ==
select tests.as_superuser();
select tests.throws_ok($$update identity.memberships set role = 'doctor' where tenant_id = '11111111-1111-4111-8111-111111111111' and role = 'tenant_admin'$$,
  '55000', 'the last admin cannot be demoted');
select tests.throws_ok($$update identity.memberships set status = 'suspended' where tenant_id = '11111111-1111-4111-8111-111111111111' and role = 'tenant_admin'$$,
  '55000', 'the last admin cannot be suspended');
select tests.throws_ok($$delete from identity.memberships where tenant_id = '11111111-1111-4111-8111-111111111111' and role = 'tenant_admin'$$,
  '55000', 'the last admin cannot be deleted');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0e300000-0000-4000-8000-000000000001', null, 'tenant_admin', 'active');
select tests.ok(tests.affected_rows($$update identity.memberships set role = 'doctor' where tenant_id = '11111111-1111-4111-8111-111111111111'
  and role = 'tenant_admin' and user_id = '0a000000-0000-4000-8000-000000000001'$$) = 1, 'with a second admin, one can be demoted');

-- ============================================ 7. tenant events ==
insert into auth.users (id, email, role, aud) values ('0e300000-0000-4000-8000-000000000002', 'op-br@medicore.example', 'authenticated', 'authenticated');
select identity.grant_platform_admin('op-br@medicore.example');
select tests.authenticate_as('op-br@medicore.example');
create temporary table t_br on commit drop as
  select * from identity.platform_create_tenant('zz-br-one', 'Zz BR One', 'Asia/Kolkata', 'zz-br@zz-br.example');
grant select on t_br to public;
select identity.platform_set_tenant_status((select tenant_id from t_br), 'suspended', 'synthetic test');
select tests.as_superuser();
select tests.ok(exists (select 1 from messaging.outbox o join identity.tenants t on t.id = o.aggregate_id
                         where t.code = 'zz-br-one' and o.event_type = 'tenant.created' and o.source_service = 'identity'), 'tenant.created in the outbox');
select tests.ok(exists (select 1 from messaging.outbox o join identity.tenants t on t.id = o.aggregate_id
                         where t.code = 'zz-br-one' and o.event_type = 'tenant.suspended'), 'tenant.suspended in the outbox');
select tests.ok((select count(*) from audit.audit_log a join identity.tenants t on t.id = a.record_id
                  where t.code = 'zz-br-one' and a.table_name = 'tenants') >= 2, 'tenant create + suspend are in the audit log');
select tests.as_anon();
select identity.submit_tenant_signup('Zz BR Approved', 'Asia/Kolkata', 'Zz Contact', 'zz-appr@zz-br.example', '+91 98000 00199', 'Pune', 'src-br');
select tests.authenticate_as('op-br@medicore.example');
create temporary table t_appr on commit drop as
  select * from identity.platform_approve_signup((select id from identity.platform_list_signups('pending') where hospital_name = 'Zz BR Approved'), 'zz-br-approved');
select tests.as_superuser();
select tests.ok(exists (select 1 from messaging.outbox o join identity.tenants t on t.id = o.aggregate_id
                         where t.code = 'zz-br-approved' and o.event_type = 'tenant.approved'), 'tenant.approved in the outbox');

-- ============================================ 8. ABHA ==
select tests.throws_ok($$update patient.patients set abha_number = '12345678901234' where id = 'aa000000-0000-4000-8000-000000000001'$$,
  '23514', 'ABHA must be formatted XX-XXXX-XXXX-XXXX');
update patient.patients set abha_number = '12-3456-7890-1234' where id = 'aa000000-0000-4000-8000-000000000001';
select tests.throws_ok($$update patient.patients set abha_number = '12-3456-7890-1234' where id = 'aa000000-0000-4000-8000-000000000002'$$,
  '23505', 'ABHA is unique per tenant');
select tests.ok(tests.affected_rows($$update patient.patients set abha_number = '12-3456-7890-1234' where id = 'bb000000-0000-4000-8000-000000000001'$$) = 1,
  'another tenant may hold the same ABHA');

rollback;
