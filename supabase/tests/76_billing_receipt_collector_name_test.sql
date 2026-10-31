-- Receipt collector name (20261031230000). Synthetic Zz-QA profile; rolls back.
begin;

select tests.as_superuser();
select tests.ok(
  has_function_privilege('hms_svc_billing', 'identity.staff_display_name_v1(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'identity.staff_display_name_v1(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'identity.staff_display_name_v1(uuid, uuid)', 'execute'),
  'staff names are published to the billing service only');

update identity.user_profiles set display_name = 'Zz-QA Counter 76'
where id = '0a000000-0000-4000-8000-000000000001';

select tests.ok(
  (select display_name from identity.staff_display_name_v1(
     '11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-000000000001')) = 'Zz-QA Counter 76',
  'a member of the tenant resolves to the display name');

select tests.ok(
  not exists (select 1 from identity.staff_display_name_v1(
     '22222222-2222-4222-8222-222222222222', '0a000000-0000-4000-8000-000000000001')),
  'another hospital gets no name for a user who is not its member');

select tests.ok(
  not exists (select 1 from identity.staff_display_name_v1(
     '11111111-1111-4111-8111-111111111111', gen_random_uuid())),
  'an unknown user has no name (no email fallback)');

select tests.ok(
  pg_get_functiondef('billing.receipt_json(uuid)'::regprocedure) like '%collectedByName%'
  and pg_get_functiondef('billing.receipt_json(uuid)'::regprocedure) not like '%email%',
  'receipt_json returns collectedByName and never an email');

select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
select tests.ok(
  (select display_name from identity.staff_display_name_v1(
     '11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-000000000001')) = 'Zz-QA Counter 76',
  'own tenant resolves under a signed-in claim');

rollback;
