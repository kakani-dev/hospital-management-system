-- Setup wizard state and the branch document-prefix default.
begin;

select tests.ok(
  (select bool_and(setup_step = 'done' and setup_completed_on is not null)
   from identity.tenants where code in ('demo-alpha', 'demo-beta')),
  'seeded hospitals are already set up');

select tests.ok(
  (select count(*) = 3 and bool_and(bp.doc_prefix = 'DEMO')
   from billing.branch_profile bp
   join identity.branches b on b.id = bp.branch_id
   join identity.tenants t on t.id = b.tenant_id
   where t.code in ('demo-alpha', 'demo-beta')),
  'seeded branches take DEMO from demo-alpha and demo-beta');

select tests.ok(
  billing.doc_prefix_from_hospital_code('demo-alpha') = 'DEMO'
  and billing.doc_prefix_from_hospital_code('ab-12-wiz') = 'AB12'
  and billing.doc_prefix_from_hospital_code('---') = 'OP'
  and billing.doc_prefix_from_hospital_code(null) = 'OP',
  'a prefix is the first four alphanumeric characters of the hospital code, else OP');

select tests.ok(
  not has_function_privilege('authenticated', 'billing.doc_prefix_from_hospital_code(text)', 'execute')
  and not has_function_privilege('anon', 'billing.doc_prefix_from_hospital_code(text)', 'execute')
  and not has_function_privilege('anon', 'identity.setup_state_v1()', 'execute')
  and not has_function_privilege('anon', 'identity.advance_setup_v1(text)', 'execute')
  and has_function_privilege('authenticated', 'identity.setup_state_v1()', 'execute')
  and has_function_privilege('hms_svc_identity', 'identity.advance_setup_v1(text)', 'execute'),
  'clients call the identity setup functions only; the billing helper stays internal');

select tests.ok(
  not has_column_privilege('authenticated', 'identity.tenants', 'setup_step', 'update')
  and not has_column_privilege('authenticated', 'identity.tenants', 'setup_completed_on', 'update')
  and has_column_privilege('authenticated', 'identity.branches', 'address', 'insert')
  and has_column_privilege('authenticated', 'identity.branches', 'address', 'update')
  and has_column_privilege('hms_svc_identity', 'identity.branches', 'address', 'update'),
  'setup columns are not client-writable; branch address is');

select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$update identity.tenants set setup_step = 'profile' where code = 'demo-alpha'$$,
  '42501',
  'a tenant admin cannot update setup columns directly');

insert into identity.branches (tenant_id, code, name)
values ('11111111-1111-4111-8111-111111111111', 'prefix', 'Prefix Clinic (synthetic)');
select tests.as_superuser();
select tests.ok(
  (select bp.doc_prefix from billing.branch_profile bp
    join identity.branches b on b.id = bp.branch_id
   where b.code = 'prefix' and b.tenant_id = '11111111-1111-4111-8111-111111111111') = 'DEMO',
  'a branch created without a prefix stores the hospital prefix');

select tests.authenticate_as('consultant@shared.example');
select tests.throws_ok($$select * from identity.setup_state_v1()$$, 'P0002',
  'two active tenants and no claim is not a setup context');
select tests.authenticate_as('consultant@shared.example', jsonb_build_object('tenant_id', '11111111-1111-4111-8111-111111111111'));
select tests.throws_ok($$select * from identity.setup_state_v1()$$, '42501',
  'a non-admin with a tenant claim cannot read setup');
select tests.authenticate_as('doctor@beta.example');
select tests.throws_ok($$select * from identity.advance_setup_v1('done')$$, '42501',
  'a doctor cannot advance setup');

select tests.authenticate_as('admin@alpha.example', jsonb_build_object('tenant_id', '11111111-1111-4111-8111-111111111111'));
select tests.ok(
  (select step = 'done' and completed_on is not null and document_prefix = 'DEMO'
   from identity.setup_state_v1()),
  'the alpha admin reads a completed setup and the DEMO prefix');
select tests.throws_ok($$select * from identity.advance_setup_v1('profile')$$, '55000',
  'a completed setup cannot be reopened');
select tests.ok((select step = 'done' from identity.advance_setup_v1('done')),
  'advancing an already finished setup to done is idempotent');

-- A brand-new hospital opens on the profile step. The first admin accepts, then walks the steps.
select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e000000-0000-4000-8000-0000000000a1', 'wizard-platform@medicore.example', 'authenticated', 'authenticated');
insert into identity.platform_admins (user_id) values ('0e000000-0000-4000-8000-0000000000a1');
select tests.authenticate_as('wizard-platform@medicore.example');
create temporary table t_wiz on commit drop as
  select identity.create_tenant('ab-12-wiz', 'Wizard Hospital (synthetic)', 'Asia/Kolkata', 'outsider@example.test') as id;
grant select on t_wiz to public;
select tests.as_superuser();
create temporary table t_wiz_m on commit drop as
  select id as membership_id from identity.memberships where tenant_id = (select id from t_wiz);
grant select on t_wiz_m to public;
select tests.ok(
  (select setup_step = 'profile' and setup_completed_on is null from identity.tenants where id = (select id from t_wiz)),
  'create_tenant starts the wizard on the profile step');
select tests.ok(
  (select bp.doc_prefix = 'AB12'
   from billing.branch_profile bp
   join identity.branches b on b.id = bp.branch_id
   where b.tenant_id = (select id from t_wiz) and b.code = 'main'),
  'the default branch is prefixed from the hospital code');

select tests.authenticate_as('outsider@example.test');
select identity.accept_membership((select membership_id from t_wiz_m));
select tests.throws_ok($$select * from identity.advance_setup_v1('staff')$$, '22023',
  'setup cannot skip a step');
select tests.throws_ok($$select * from identity.advance_setup_v1('done')$$, '22023',
  'setup cannot jump to done');

select tests.as_superuser();
update identity.branches set is_active = false where tenant_id = (select id from t_wiz);
select tests.authenticate_as('outsider@example.test');
select tests.ok((select step = 'branch' from identity.advance_setup_v1('branch')),
  'the profile step advances to the branch step');
select tests.throws_ok($$select * from identity.advance_setup_v1('staff')$$, '55000',
  'leaving the branch step needs a live branch');
select tests.as_superuser();
update identity.branches set is_active = true where tenant_id = (select id from t_wiz);
select tests.authenticate_as('outsider@example.test');
select tests.ok((select step = 'staff' from identity.advance_setup_v1('staff')), 'staff is optional and next');
select tests.ok((select step = 'schedule' from identity.advance_setup_v1('schedule')), 'schedule is optional and next');
select tests.ok((select step = 'profile' from identity.advance_setup_v1('profile')), 'the wizard can move back');
select tests.ok((select step = 'branch' from identity.advance_setup_v1('branch')), 'and forward again, one step');
select tests.ok((select step = 'staff' from identity.advance_setup_v1('staff')), 'back on staff');
select tests.ok((select step = 'schedule' from identity.advance_setup_v1('schedule')), 'back on schedule');
select tests.ok(
  (select step = 'done' and completed_on is not null from identity.advance_setup_v1('done')),
  'done stamps setup_completed_on');
select tests.ok((select step = 'done' from identity.advance_setup_v1('done')),
  'a second done does not reopen the wizard');
select tests.throws_ok($$select * from identity.advance_setup_v1('schedule')$$, '55000',
  'done cannot move back');

select tests.as_superuser();
select tests.ok(
  (select count(*) = 1
      and bool_and(o.source_service = 'identity')
      and bool_and(o.payload ? 'tenant_id' and o.payload ? 'step' and o.payload ? 'previous_step' and o.payload ? 'at')
      and bool_and(not (o.payload ? 'name') and not (o.payload ? 'code'))
      and bool_and(o.payload ->> 'step' = 'done' and o.payload ->> 'previous_step' = 'schedule')
   from messaging.outbox o
   where o.aggregate_type = 'tenant' and o.aggregate_id = (select id from t_wiz) and o.event_type = 'tenant.setup_completed'),
  'finishing setup enqueues tenant.setup_completed with ids and the step only');
select tests.ok(
  (select count(*) >= 1 from messaging.outbox o
   where o.aggregate_id = (select id from t_wiz) and o.event_type = 'tenant.setup_step_changed'),
  'earlier steps enqueue tenant.setup_step_changed');

select tests.authenticate_as('outsider@example.test');
insert into identity.branches (tenant_id, code, name, address)
values ((select id from t_wiz), 'east', 'East Wing (synthetic)', '1 Synthetic Road');
select tests.as_superuser();
select tests.ok(
  (select address = '1 Synthetic Road' and bp.doc_prefix = 'AB12'
   from identity.branches b
   join billing.branch_profile bp on bp.branch_id = b.id
   where b.tenant_id = (select id from t_wiz) and b.code = 'east'),
  'another branch keeps the same prefix and stores its address');

rollback;
