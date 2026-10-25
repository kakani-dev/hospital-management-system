-- Visit types, follow-up snapshots and NMC registration. Migration 20261025280000.
begin;

select tests.ok(
  (select count(*) from appointment.visit_types where tenant_id = '11111111-1111-4111-8111-111111111111' and not is_deleted) = 5
  and exists (select 1 from appointment.visit_types where tenant_id = '11111111-1111-4111-8111-111111111111' and code = 'new_consult' and follow_up_valid_days = 7 and follow_up_fee_paise = 0),
  'each tenant receives the five default visit types');

select tests.authenticate_as('admin@alpha.example');
select appointment.ensure_default_visit_types('11111111-1111-4111-8111-111111111111');
select tests.ok(
  (select count(*) from appointment.visit_types where tenant_id = '11111111-1111-4111-8111-111111111111' and not is_deleted) = 5,
  'ensure_default_visit_types is idempotent');

select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$insert into appointment.visit_types (tenant_id, code, name, default_fee_paise, duration_minutes)
    values ('11111111-1111-4111-8111-111111111111', 'extra', 'Extra', 100, 15)$$,
  '42501', 'receptionist cannot create visit types');
select tests.throws_ok(
  $$insert into appointment.departments (tenant_id, name) values ('11111111-1111-4111-8111-111111111111', 'Ward')$$,
  '42501', 'receptionist cannot create departments');

select tests.authenticate_as('admin@beta.example');
select tests.ok(
  (select count(*) from appointment.visit_types where tenant_id = '11111111-1111-4111-8111-111111111111') = 0,
  'cross-tenant: Beta admin sees no Alpha visit types');
select tests.ok(
  tests.affected_rows($$update appointment.visit_types set default_fee_paise = 1 where tenant_id = '11111111-1111-4111-8111-111111111111'$$) = 0,
  'cross-tenant: Beta admin cannot edit an Alpha visit type');

select tests.as_superuser();
update identity.tenants set status = 'suspended' where id = '22222222-2222-4222-8222-222222222222';
select tests.authenticate_as('admin@beta.example');
select tests.ok((select count(*) from appointment.visit_types) = 0, 'a suspended tenant sees no visit types');
select tests.as_superuser();
update identity.tenants set status = 'active' where id = '22222222-2222-4222-8222-222222222222';

-- Registration: format, case, same-tenant duplicate (the race backstop), other tenant, reuse after delete.
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$insert into appointment.practitioners (tenant_id, display_name, registration_number)
    values ('11111111-1111-4111-8111-111111111111', 'Dr. Lower (synthetic)', 'kmc/2018/12345')$$,
  '23514', 'lowercase registration fails the format check');
insert into appointment.practitioners (id, tenant_id, display_name, registration_number)
values ('c1111111-0000-4000-8000-0000000000a1', '11111111-1111-4111-8111-111111111111', 'Dr. Council (synthetic)', 'KMC/2018/12345');
select tests.throws_ok(
  $$insert into appointment.practitioners (tenant_id, display_name, registration_number)
    values ('11111111-1111-4111-8111-111111111111', 'Dr. Race (synthetic)', 'KMC/2018/12345')$$,
  '23505', 'duplicate registration in one tenant is a unique violation');
select tests.ok(
  (select count(*) from appointment.practitioners where registration_number = 'KMC/2018/12345') = 1,
  'the failed duplicate insert does not leave a second doctor');
insert into appointment.practitioners (id, tenant_id, display_name)
values ('c1111111-0000-4000-8000-0000000000a2', '11111111-1111-4111-8111-111111111111', 'Dr. No NMC (synthetic)');
select tests.ok(
  (select count(*) from appointment.practitioners where tenant_id = '11111111-1111-4111-8111-111111111111' and registration_number is null) >= 2,
  'doctors without a registration number do not collide');

select tests.authenticate_as('admin@beta.example');
insert into appointment.practitioners (id, tenant_id, display_name, registration_number)
values ('c2222222-0000-4000-8000-0000000000a1', '22222222-2222-4222-8222-222222222222', 'Dr. Beta Council (synthetic)', 'KMC/2018/12345');
select tests.ok(true, 'the same registration is allowed in another tenant');

select tests.authenticate_as('admin@alpha.example');
select appointment.soft_delete_practitioner('c1111111-0000-4000-8000-0000000000a1');
insert into appointment.practitioners (id, tenant_id, display_name, registration_number)
values ('c1111111-0000-4000-8000-0000000000a3', '11111111-1111-4111-8111-111111111111', 'Dr. Reused (synthetic)', 'KMC/2018/12345');
select tests.ok(true, 'a deleted doctor''s registration can be used again');

-- Snapshot: editing or soft-deleting the visit type does not change the booking or the published fee.
insert into appointment.appointments (
  id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at,
  visit_type_id, consultation_fee_paise, granted_follow_up_days, granted_follow_up_fee_paise)
select 'e1111111-0000-4000-8000-0000000000c1', '11111111-1111-4111-8111-111111111111',
       'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
       'aa000000-0000-4000-8000-000000000001', '2026-09-01 04:00+00', '2026-09-01 04:30+00',
       id, 50000, 7, 0
from appointment.visit_types
where tenant_id = '11111111-1111-4111-8111-111111111111' and code = 'new_consult';
update appointment.visit_types set default_fee_paise = 90000, duration_minutes = 45, follow_up_fee_paise = 15000, follow_up_valid_days = 2
where tenant_id = '11111111-1111-4111-8111-111111111111' and code = 'new_consult';
select tests.ok(
  (select consultation_fee_paise = 50000 and granted_follow_up_days = 7 and granted_follow_up_fee_paise = 0
     and ends_at = '2026-09-01 04:30+00'
   from appointment.appointments where id = 'e1111111-0000-4000-8000-0000000000c1'),
  'editing a visit type does not change an existing booking');
update appointment.appointments set status = 'no_show' where id = 'e1111111-0000-4000-8000-0000000000c1';
select tests.ok(
  (select status = 'no_show' and consultation_fee_paise = 50000 from appointment.appointments where id = 'e1111111-0000-4000-8000-0000000000c1'),
  'a no-show keeps the snapshotted fee');

select tests.throws_ok(
  $$update appointment.appointments set consultation_fee_paise = 1 where id = 'e1111111-0000-4000-8000-0000000000c1'$$,
  '42501', 'the fee snapshot is not client-updatable');
select tests.ok(
  not has_column_privilege('authenticated', 'appointment.appointments', 'granted_follow_up_days', 'UPDATE')
  and has_column_privilege('authenticated', 'appointment.appointments', 'granted_follow_up_days', 'INSERT')
  and not has_column_privilege('hms_svc_scheduling', 'appointment.appointments', 'granted_follow_up_fee_paise', 'UPDATE'),
  'follow-up snapshots are insert-only for the scheduling role');

select appointment.soft_delete_visit_type((
  select id from appointment.visit_types
  where tenant_id = '11111111-1111-4111-8111-111111111111' and code = 'new_consult'));
select tests.ok(
  (select visit_type_id is not null and consultation_fee_paise = 50000
   from appointment.appointments where id = 'e1111111-0000-4000-8000-0000000000c1'),
  'soft-deleting a visit type keeps the booking');

-- Second override insert loses the race; a later request updates the same row.
insert into appointment.visit_type_overrides (id, tenant_id, visit_type_id, branch_id, fee_paise)
select 'f2111111-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', id,
       'a1111111-0000-4000-8000-000000000002', 100
from appointment.visit_types
where tenant_id = '11111111-1111-4111-8111-111111111111' and code = 'follow_up';
select tests.throws_ok(
  $$insert into appointment.visit_type_overrides (tenant_id, visit_type_id, branch_id, fee_paise)
    select '11111111-1111-4111-8111-111111111111', id, 'a1111111-0000-4000-8000-000000000002', 250
    from appointment.visit_types
    where tenant_id = '11111111-1111-4111-8111-111111111111' and code = 'follow_up'$$,
  '23505', 'two override inserts for the same branch collide');
update appointment.visit_type_overrides set fee_paise = 250 where id = 'f2111111-0000-4000-8000-000000000001';
select tests.ok(
  (select count(*) = 1 and bool_or(fee_paise = 250) from appointment.visit_type_overrides
    where tenant_id = '11111111-1111-4111-8111-111111111111' and branch_id = 'a1111111-0000-4000-8000-000000000002'),
  'the retry updates the existing override');

select tests.as_superuser();
select tests.ok(
  (select visit_type_code is null and consultation_fee_paise = 50000
   from appointment.appointment_consultation_fee_v1('11111111-1111-4111-8111-111111111111', 'e1111111-0000-4000-8000-0000000000c1')),
  'published fee still returns the snapshot after the visit type is deleted');
select tests.ok(
  (select registration_number is null and specialty is null
   from appointment.practitioner_credential_v1('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-0000000000a2')),
  'a doctor without NMC data returns null registration and null specialty');
select tests.ok(
  (select registration_number = 'NMC/1000001' and department_name = 'General medicine'
   from appointment.practitioner_credential_v1('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000002')),
  'seeded synthetic registration is readable by the billing contract');
select tests.ok(
  has_function_privilege('hms_svc_billing', 'appointment.practitioner_credential_v1(uuid, uuid)', 'execute')
  and has_function_privilege('hms_svc_billing', 'appointment.appointment_consultation_fee_v1(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'appointment.practitioner_credential_v1(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'appointment.appointment_consultation_fee_v1(uuid, uuid)', 'execute')
  and not has_function_privilege('hms_svc_scheduling', 'appointment.practitioner_credential_v1(uuid, uuid)', 'execute'),
  'credential and fee contracts are billing and service_role only');

-- Check-in copies a non-null snapshot onto the consult draft. 0 is free, not "missing".
insert into appointment.appointments (
  id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at,
  visit_type_id, consultation_fee_paise)
select 'e1111111-0000-4000-8000-0000000000c2', '11111111-1111-4111-8111-111111111111',
       'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
       'aa000000-0000-4000-8000-000000000001', '2027-03-01 04:00+00', '2027-03-01 04:15+00',
       id, 0
from appointment.visit_types
where tenant_id = '11111111-1111-4111-8111-111111111111' and code = 'follow_up' and not is_deleted;
insert into appointment.appointments (
  id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
values (
  'e1111111-0000-4000-8000-0000000000c3', '11111111-1111-4111-8111-111111111111',
  'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
  'aa000000-0000-4000-8000-000000000001', '2027-03-01 05:00+00', '2027-03-01 05:15+00');
select set_config('appointment.check_in', 'e1111111-0000-4000-8000-0000000000c2', true);
update appointment.appointments set status = 'checked_in' where id = 'e1111111-0000-4000-8000-0000000000c2';
select set_config('appointment.check_in', 'e1111111-0000-4000-8000-0000000000c3', true);
update appointment.appointments set status = 'checked_in' where id = 'e1111111-0000-4000-8000-0000000000c3';
select set_config('appointment.check_in', '', true);
select tests.ok(
  (select l.unit_price_paise = 0
   from billing.bill_line l
   join billing.bill b on b.id = l.bill_id
   join billing.billing_account a on a.id = b.account_id
   where a.source_ref_id = 'e1111111-0000-4000-8000-0000000000c2' and not l.is_deleted),
  'a free follow-up snapshot replaces the catalog price on the consult draft');
update appointment.visit_types set follow_up_fee_paise = 99999
where tenant_id = '11111111-1111-4111-8111-111111111111' and code = 'follow_up';
select tests.ok(
  (select l.unit_price_paise = 0
   from billing.bill_line l
   join billing.bill b on b.id = l.bill_id
   join billing.billing_account a on a.id = b.account_id
   where a.source_ref_id = 'e1111111-0000-4000-8000-0000000000c2' and not l.is_deleted),
  'editing the visit type after check-in does not change the draft line');
select tests.ok(
  (select l.unit_price_paise = 50000
   from billing.bill_line l
   join billing.bill b on b.id = l.bill_id
   join billing.billing_account a on a.id = b.account_id
   where a.source_ref_id = 'e1111111-0000-4000-8000-0000000000c3' and not l.is_deleted),
  'a booking with no visit-type fee keeps the catalog CONSULT price');

select set_config('request.jwt.claims', '{"sub":"0a000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
set local role hms_svc_billing;
select billing.add_line(
  '11111111-1111-4111-8111-111111111111',
  (select b.id from billing.bill b
   join billing.billing_account a on a.id = b.account_id
   where a.source_ref_id = 'e1111111-0000-4000-8000-0000000000c3' and not b.is_deleted
   limit 1),
  jsonb_build_object('code', 'CONSULT', 'unitPricePaise', 1));
select tests.ok(
  (select l.unit_price_paise = 50000
   from billing.bill_line l
   join billing.bill b on b.id = l.bill_id
   join billing.billing_account a on a.id = b.account_id
   where a.source_ref_id = 'e1111111-0000-4000-8000-0000000000c3' and not l.is_deleted
   order by l.line_no desc
   limit 1),
  'a client unit price on add_line is ignored');

rollback;
