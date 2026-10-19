-- Custom access token hook, active-context switching and member management functions.
begin;

-- ---------- hook privileges ----------
select tests.ok(has_function_privilege('supabase_auth_admin', 'identity.custom_access_token_hook(jsonb)', 'execute'),
  'supabase_auth_admin can execute the access token hook');
select tests.ok(not has_function_privilege('authenticated', 'identity.custom_access_token_hook(jsonb)', 'execute')
  and not has_function_privilege('anon', 'identity.custom_access_token_hook(jsonb)', 'execute'),
  'anon/authenticated cannot execute the access token hook');
select tests.ok(not has_function_privilege('authenticated', 'identity.resolve_active_context(uuid)', 'execute'),
  'internal resolver (takes an arbitrary user id) is not executable by clients');

-- ---------- hook output (run exactly as Supabase Auth does) ----------
set local role supabase_auth_admin;

select tests.ok(
  (identity.custom_access_token_hook(jsonb_build_object(
     'user_id', '0a000000-0000-4000-8000-000000000001',
     'claims', jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'aud', 'authenticated')))
   -> 'claims') @> '{"tenant_id": "11111111-1111-4111-8111-111111111111", "hms_roles": ["tenant_admin"], "sub": "0a000000-0000-4000-8000-000000000001", "role": "authenticated"}',
  'hook adds tenant_id + roles for alpha admin and keeps required claims');
select tests.ok(
  jsonb_array_length(identity.custom_access_token_hook(jsonb_build_object(
     'user_id', '0a000000-0000-4000-8000-000000000001', 'claims', '{}'::jsonb)) -> 'claims' -> 'branch_ids') = 2,
  'hook lists both Alpha branches for a tenant-wide admin');
select tests.ok(
  (identity.custom_access_token_hook(jsonb_build_object(
     'user_id', '0a000000-0000-4000-8000-000000000002', 'claims', '{}'::jsonb)) -> 'claims' -> 'branch_ids')
   = '["a1111111-0000-4000-8000-000000000001"]'::jsonb,
  'hook limits branch_ids to the receptionist''s branch');
select tests.ok(
  not ((identity.custom_access_token_hook(jsonb_build_object(
     'user_id', '0c000000-0000-4000-8000-000000000001',
     'claims', jsonb_build_object('tenant_id', '22222222-2222-4222-8222-222222222222', 'hms_roles', '["tenant_admin"]'::jsonb)))
   -> 'claims') ?| array['tenant_id', 'hms_roles', 'branch_ids']),
  'hook strips forged tenant claims and adds none for a user without memberships');
select tests.ok(
  (identity.custom_access_token_hook(jsonb_build_object(
     'user_id', '0d000000-0000-4000-8000-000000000001', 'claims', '{}'::jsonb)) -> 'claims' ->> 'tenant_id')
   = '11111111-1111-4111-8111-111111111111',
  'multi-tenant consultant defaults deterministically by membership age, then tenant id (Alpha)');
select tests.ok(
  (identity.custom_access_token_hook(jsonb_build_object('user_id', 'not-a-uuid', 'claims', '{"sub":"x"}'::jsonb)) -> 'claims') = '{"sub":"x"}',
  'hook never fails sign-in: bad input returns the original claims');
reset role;

-- ---------- set_active_context (switch tenant/branch) ----------
select tests.authenticate_as('consultant@shared.example');
select identity.set_active_context('22222222-2222-4222-8222-222222222222');
select tests.as_superuser();
set local role supabase_auth_admin;
select tests.ok(
  (identity.custom_access_token_hook(jsonb_build_object(
     'user_id', '0d000000-0000-4000-8000-000000000001', 'claims', '{}'::jsonb)) -> 'claims' ->> 'tenant_id')
   = '22222222-2222-4222-8222-222222222222',
  'after switching, the next token carries the Beta tenant');
reset role;

select tests.authenticate_as('consultant@shared.example');
select tests.throws_ok(
  $$select identity.set_active_context('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001')$$,
  '42501', 'cannot switch to a branch outside the membership branch scope');
select identity.set_active_context('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002');
select tests.ok(
  (select tenant_id = '11111111-1111-4111-8111-111111111111' and branch_id = 'a1111111-0000-4000-8000-000000000002'
   from identity.my_active_context()),
  'switching to an allowed branch is stored and returned by my_active_context()');

select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$select identity.set_active_context('22222222-2222-4222-8222-222222222222')$$,
  '42501', 'cannot switch to a tenant without membership');
select tests.throws_ok(
  $$select identity.set_active_context('11111111-1111-4111-8111-111111111111', 'b2222222-0000-4000-8000-000000000001')$$,
  '42501', 'cannot switch to another tenant''s branch');

-- my_memberships ignores the token pin (switcher needs all tenants), but only for the caller
select tests.authenticate_as('consultant@shared.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.ok((select count(distinct tenant_id) from identity.my_memberships()) = 2,
  'my_memberships() lists every tenant of the caller');
select tests.authenticate_as('outsider@example.test');
select tests.ok((select count(*) from identity.my_memberships()) = 0, 'outsider has no memberships');
select tests.ok((select count(*) from identity.my_active_context()) = 0, 'outsider has no active context');

-- ---------- add_member (invite; consent required, see also 08_membership_invite_consent_test) ----------
select tests.authenticate_as('admin@alpha.example');
select tests.ok(identity.add_member('11111111-1111-4111-8111-111111111111', 'OUTSIDER@example.test', 'nurse', 'a1111111-0000-4000-8000-000000000002') is not null,
  'tenant admin invites an existing user (case-insensitive email) with role + branch scope');
select tests.ok((select count(*) from identity.memberships where user_id = '0c000000-0000-4000-8000-000000000001') = 0,
  'the pending invitation is NOT visible to the admin');
select tests.ok(identity.add_member('11111111-1111-4111-8111-111111111111', 'nobody@nowhere.example', 'nurse') is null,
  'unknown email returns NULL (no exception, no enumeration)');
select tests.ok(
  identity.add_member('11111111-1111-4111-8111-111111111111', 'outsider@example.test', 'nurse', 'a1111111-0000-4000-8000-000000000002')
  = identity.add_member('11111111-1111-4111-8111-111111111111', 'outsider@example.test', 'doctor', 'a1111111-0000-4000-8000-000000000002'),
  'repeat invite for the same (tenant, branch) returns the existing membership id (no exception)');
select tests.throws_ok(
  $$select identity.add_member('11111111-1111-4111-8111-111111111111', 'doctor@beta.example', 'superuser')$$,
  '23514', 'invalid role is rejected');
select tests.throws_ok(
  $$select identity.add_member('11111111-1111-4111-8111-111111111111', 'doctor@beta.example', 'nurse', 'b2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'branch from another tenant is rejected (looks unknown: 404-not-403)');
select tests.throws_ok(
  $$select identity.add_member('22222222-2222-4222-8222-222222222222', 'admin@alpha.example', 'tenant_admin')$$,
  '42501', 'admin cannot add members to another tenant');

select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$select identity.add_member('11111111-1111-4111-8111-111111111111', 'doctor@beta.example', 'tenant_admin')$$,
  '42501', 'non-admin cannot add members');

select tests.authenticate_as('outsider@example.test');
select tests.ok((select count(*) from identity.my_memberships()) = 0, 'an invitation grants no membership before acceptance');
select identity.accept_membership((select membership_id from identity.my_invitations()));
select tests.ok(
  (select array_agg(role) from identity.my_memberships()) = array['nurse'],
  'after accepting, the invitee sees their new membership (original invite unchanged)');

-- Suspended members: admins still see their profile, colleagues do not.
select tests.as_superuser();
update identity.memberships set status = 'suspended'
 where user_id = '0c000000-0000-4000-8000-000000000001' and tenant_id = '11111111-1111-4111-8111-111111111111';
select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  (select count(*) from identity.user_profiles where id = '0c000000-0000-4000-8000-000000000001') = 1,
  'tenant admin still sees the profile of a suspended member');
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  (select count(*) from identity.user_profiles where id = '0c000000-0000-4000-8000-000000000001') = 0,
  'non-admin colleague does not see a suspended member''s profile');
select tests.authenticate_as('admin@beta.example');
select tests.ok(
  (select count(*) from identity.user_profiles where id = '0c000000-0000-4000-8000-000000000001') = 0,
  'admin of another tenant does not see the profile');

rollback;
