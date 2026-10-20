-- Business-logic audit 2026-10-20: new-tenant journey end to end (both onboarding paths),
-- tenant-code rules, isolation, and the bookable-window rule (future + inside a schedule).
-- Self-contained, synthetic Zz- data only.
begin;

select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e290000-0000-4000-8000-000000000001', 'op-bl@medicore.example', 'authenticated', 'authenticated'),
  ('0e290000-0000-4000-8000-000000000002', 'zz-admin@zz-bl.example', 'authenticated', 'authenticated'),
  ('0e290000-0000-4000-8000-000000000003', 'zz-other@zz-bl.example', 'authenticated', 'authenticated'),
  ('0e290000-0000-4000-8000-000000000004', 'zz-admin2@zz-bl.example', 'authenticated', 'authenticated');
select identity.grant_platform_admin('op-bl@medicore.example');

-- ---------- only the platform admin ----------
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$select * from identity.platform_create_tenant('zz-bl-x', 'Zz BL X', 'Asia/Kolkata', 'x@zz-bl.example')$$,
  '42501', 'a tenant admin cannot create a hospital');
select tests.throws_ok($$select identity.create_tenant('zz-bl-y', 'Zz BL Y', 'Asia/Kolkata')$$,
  '42501', 'a tenant admin cannot call create_tenant directly');

-- ---------- direct create ----------
select tests.authenticate_as('op-bl@medicore.example');
select tests.throws_ok($$select * from identity.platform_create_tenant('zz-bl-z', 'Zz BL Z', 'IST', 'x@zz-bl.example')$$,
  '22023', 'time zone must be a valid IANA zone');
select tests.throws_ok($$select * from identity.platform_create_tenant('zz-bl-z', 'Zz BL Z', null, 'x@zz-bl.example')$$,
  '22023', 'time zone is required');
select tests.throws_ok($$select * from identity.platform_create_tenant('ZZ BL!', 'Zz BL Z', 'Asia/Kolkata', 'x@zz-bl.example')$$,
  '23514', 'hospital code must be lowercase letters, digits and dashes');
create temporary table t_new on commit drop as
  select * from identity.platform_create_tenant('zz-bl-direct', 'Zz BL Direct', 'Asia/Kolkata', 'zz-admin@zz-bl.example');
grant select on t_new to public;
select tests.throws_ok($$select * from identity.platform_create_tenant('zz-bl-direct', 'Zz BL Dup', 'Asia/Kolkata', 'y@zz-bl.example')$$,
  '23505', 'hospital code is unique (double submit is rejected, no second tenant)');

select tests.as_superuser();
select tests.ok((select count(*) = 1 from identity.tenants where code = 'zz-bl-direct'), 'exactly one tenant for the code');
select tests.ok((select count(*) = 1 and bool_and(b.code = 'main' and b.timezone_override is null)
                 from identity.branches b join t_new on b.tenant_id = t_new.tenant_id where not b.is_deleted),
  'direct create: one default Main branch inheriting the tenant zone');
select tests.ok((select t.default_country_code = '+91' and t.created_by is not null and t.created_on is not null
                 from identity.tenants t join t_new on t.id = t_new.tenant_id),
  'default_country_code derived from Asia/Kolkata (+91); audit columns stamped');
select tests.ok((select expires_on > now() from t_new), 'first-admin invite link issued with a future expiry');

-- code is immutable
select tests.authenticate_as('op-bl@medicore.example');
select tests.throws_ok($$update identity.tenants set code = 'zz-bl-renamed' where code = 'zz-bl-direct'$$,
  '42501', 'clients cannot rename a hospital code (no UPDATE on tenants)');

-- ---------- invite: email must match, single use ----------
select tests.authenticate_as('zz-other@zz-bl.example');
select tests.throws_ok(format('select identity.claim_invite_link(%L)', (select token from t_new)),
  '42501', 'invite cannot be claimed by a different email');
select tests.authenticate_as('zz-admin@zz-bl.example');
select identity.claim_invite_link((select token from t_new));
select tests.ok((select count(*) = 1 from identity.my_memberships() m where m.tenant_id = (select tenant_id from t_new)),
  'the invited first admin gets one membership');
select tests.throws_ok(format('select identity.claim_invite_link(%L)', (select token from t_new)),
  'P0002', 'invite links are single-use');

-- ---------- new admin works end to end immediately ----------
select identity.set_active_context((select tenant_id from t_new), null);
select tests.authenticate_as('zz-admin@zz-bl.example');
insert into identity.branches (id, tenant_id, code, name)
  values ('b2900000-0000-4000-8000-000000000001', (select tenant_id from t_new), 'east', 'Zz East');
select tests.ok(exists (select 1 from identity.branches where id = 'b2900000-0000-4000-8000-000000000001'),
  'new admin creates a branch right after accepting');
select tests.throws_ok(format($$insert into identity.branches (tenant_id, code, name) values (%L, 'east', 'Zz East 2')$$, (select tenant_id from t_new)),
  '23505', 'branch codes are unique per tenant');
insert into appointment.practitioners (id, tenant_id, display_name)
  values ('c2900000-0000-4000-8000-000000000001', (select tenant_id from t_new), 'Dr. Zz-BL');
insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
  select (select tenant_id from t_new), 'c2900000-0000-4000-8000-000000000001', 'b2900000-0000-4000-8000-000000000001',
         w, '09:00', '17:00', 15, current_date - 1 from generate_series(1, 7) w;
select tests.throws_ok(format($$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
  values (%L, 'c2900000-0000-4000-8000-000000000001', 'b2900000-0000-4000-8000-000000000001', 1, '16:00', '18:00', 15, current_date)$$, (select tenant_id from t_new)),
  '23P01', 'overlapping schedules for the same practitioner are rejected');
select tests.throws_ok(format($$insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from, valid_to)
  values (%L, 'c2900000-0000-4000-8000-000000000001', 'b2900000-0000-4000-8000-000000000001', 1, '18:00', '19:00', 15, current_date, current_date - 1)$$, (select tenant_id from t_new)),
  '23514', 'valid_to must not be before valid_from');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name, date_of_birth)
  values ('ab290000-0000-4000-8000-000000000001', (select tenant_id from t_new), 'b2900000-0000-4000-8000-000000000001', 'Zz', 'BL-Patient', '1990-01-01');
select tests.ok((select mrn is not null from patient.patients where id = 'ab290000-0000-4000-8000-000000000001'),
  'new tenant: first patient gets a server MRN (counter initialised on first use)');

-- bookable window: future + inside schedule (branch-local)
create temporary table t_slot on commit drop as
  select * from appointment.available_slots((select tenant_id from t_new), 'b2900000-0000-4000-8000-000000000001',
    current_date + 1, current_date + 2, 'c2900000-0000-4000-8000-000000000001') limit 1;
grant select on t_slot to public;
select tests.ok((select count(*) = 1 from t_slot), 'new tenant has free slots');
select tests.throws_ok(format('select appointment.assert_bookable_window(%L, %L, %L, now() - interval ''2 days'', now() - interval ''2 days'' + interval ''15 minutes'')',
  (select tenant_id from t_new), 'b2900000-0000-4000-8000-000000000001', 'c2900000-0000-4000-8000-000000000001'),
  '22023', 'no booking for an earlier (branch-local) day');
select appointment.assert_bookable_window((select tenant_id from t_new), 'b2900000-0000-4000-8000-000000000001',
  'c2900000-0000-4000-8000-000000000001', (select slot_start from t_slot), (select slot_end from t_slot));
select tests.ok(true, 'a future free slot passes the bookable-window check');
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
  select 'e2900000-0000-4000-8000-000000000001', (select tenant_id from t_new), 'b2900000-0000-4000-8000-000000000001',
         'c2900000-0000-4000-8000-000000000001', 'ab290000-0000-4000-8000-000000000001', slot_start, slot_end from t_slot;
select tests.throws_ok(format($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
  values (%L, 'b2900000-0000-4000-8000-000000000001', 'c2900000-0000-4000-8000-000000000001', 'ab290000-0000-4000-8000-000000000001', %L, %L)$$,
  (select tenant_id from t_new), (select slot_start from t_slot), (select slot_end from t_slot)),
  '23P01', 'the same slot cannot be booked twice');
select tests.throws_ok($$update appointment.appointments set status = 'no_show' where id = 'e2900000-0000-4000-8000-000000000001'$$,
  '23514', 'no-show only after the slot has started');

-- ---------- isolation ----------
select tests.authenticate_as('admin@alpha.example');
select tests.ok(not exists (select 1 from patient.patients where id = 'ab290000-0000-4000-8000-000000000001')
  and not exists (select 1 from identity.branches where id = 'b2900000-0000-4000-8000-000000000001')
  and not exists (select 1 from appointment.appointments where id = 'e2900000-0000-4000-8000-000000000001'),
  'another hospital sees none of the new tenant''s data');
select tests.throws_ok(format('select appointment.assert_bookable_window(%L, %L, %L, now() + interval ''1 day'', now() + interval ''25 hours'')',
  (select tenant_id from t_new), 'b2900000-0000-4000-8000-000000000001', 'c2900000-0000-4000-8000-000000000001'),
  'P0002', 'bookable-window check is tenant-scoped (foreign tenant looks unknown)');

-- ---------- outbox ----------
select tests.as_superuser();
select tests.ok(exists (select 1 from messaging.outbox o where o.aggregate_id = 'e2900000-0000-4000-8000-000000000001'),
  'booking emits an outbox event');

-- ---------- approve path: same defaults, no double approve ----------
select tests.as_anon();
select identity.submit_tenant_signup('Zz BL Approved', 'America/New_York', 'Zz Admin2', 'zz-admin2@zz-bl.example', '+1 555 0199', 'NYC', 'src-bl');
select tests.authenticate_as('op-bl@medicore.example');
create temporary table t_ap on commit drop as
  select * from identity.platform_approve_signup((select id from identity.platform_list_signups('pending') where hospital_name = 'Zz BL Approved'), 'zz-bl-approved');
grant select on t_ap to public;
select tests.throws_ok(format('select * from identity.platform_approve_signup(%L, %L)',
  (select r.id from identity.platform_list_signups() r where r.hospital_name = 'Zz BL Approved'), 'zz-bl-approved-2'),
  '55000', 'a request cannot be approved twice');
select tests.as_superuser();
select tests.ok((select count(*) = 1 and bool_and(b.code = 'main' and b.timezone_override is null)
                 from identity.branches b join t_ap on b.tenant_id = t_ap.tenant_id where not b.is_deleted),
  'approve path: same single default Main branch as direct create');
select tests.ok((select t.default_country_code = '+1' and t.time_zone = 'America/New_York' from identity.tenants t join t_ap on t.id = t_ap.tenant_id),
  'approve path: zone kept, country code derived (+1)');

-- ---------- suspend blocks the hospital's users ----------
select tests.authenticate_as('op-bl@medicore.example');
select identity.platform_set_tenant_status((select tenant_id from t_new), 'suspended', 'Zz audit test');
select tests.authenticate_as('zz-admin@zz-bl.example');
select tests.ok(not exists (select 1 from patient.patients where id = 'ab290000-0000-4000-8000-000000000001')
  and not exists (select 1 from identity.current_tenant_ids()),
  'users of a suspended hospital lose access immediately');


rollback;
