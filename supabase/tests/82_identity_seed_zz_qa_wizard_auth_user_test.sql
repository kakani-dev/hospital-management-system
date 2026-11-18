-- Weekly QA harness: only platform operators may seed tagged zz-qa wizard emails;
-- execute is granted to authenticated / service_role / hms_svc_identity (the identity
-- API is the supported caller); the stored hash is not the plaintext password.
begin;

select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e820000-0000-4000-8000-000000000001', 'op-82@medicore.example', 'authenticated', 'authenticated');
select identity.grant_platform_admin('op-82@medicore.example');

select tests.ok(
  has_function_privilege('authenticated', 'identity.seed_zz_qa_wizard_auth_user(text, text)', 'execute')
  and has_function_privilege('hms_svc_identity', 'identity.seed_zz_qa_wizard_auth_user(text, text)', 'execute')
  and has_function_privilege('service_role', 'identity.seed_zz_qa_wizard_auth_user(text, text)', 'execute')
  and not has_function_privilege('anon', 'identity.seed_zz_qa_wizard_auth_user(text, text)', 'execute'),
  'seed is executable by operators and the identity service, not anonymously');

select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$select identity.seed_zz_qa_wizard_auth_user('zz-qa.wiz.202611181900@synthetic.example', 'Synthetic123x')$$,
  '42501',
  'a tenant admin cannot seed a wizard auth user');

select tests.authenticate_as('op-82@medicore.example');

select tests.throws_ok(
  $$select identity.seed_zz_qa_wizard_auth_user('admin@alpha.example', 'Synthetic123x')$$,
  '42501',
  'a non zz-qa wizard email is refused');

select tests.throws_ok(
  $$select identity.seed_zz_qa_wizard_auth_user('zz-qa.wiz.202611181900@synthetic.example', 'short')$$,
  '22023',
  'a weak password is refused');

create temp table seeded on commit drop as
  select identity.seed_zz_qa_wizard_auth_user('zz-qa.wiz.202611181900@synthetic.example', 'Synthetic123x') as id;

-- auth.users is not readable as authenticated; inspect the row as a superuser.
select tests.as_superuser();
select tests.ok(
  (select email_confirmed_at is not null from auth.users where id = (select id from seeded))
  and (select email from auth.users where id = (select id from seeded)) = 'zz-qa.wiz.202611181900@synthetic.example'
  and (select encrypted_password is distinct from 'Synthetic123x' and length(encrypted_password) > 20 from auth.users where id = (select id from seeded))
  and (select raw_user_meta_data->>'zz_qa' from auth.users where id = (select id from seeded)) = 'true'
  and exists (select 1 from identity.user_profiles p where p.id = (select id from seeded) and p.email = 'zz-qa.wiz.202611181900@synthetic.example'),
  'a tagged wizard user is confirmed, hashed, profiled, and never stored in clear');

select tests.authenticate_as('op-82@medicore.example');
select tests.throws_ok(
  $$select identity.seed_zz_qa_wizard_auth_user('zz-qa.wiz.202611181900@synthetic.example', 'Synthetic123x')$$,
  '23505',
  'a second seed of the same email is refused');

rollback;
