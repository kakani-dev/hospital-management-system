-- Review finding B1 / PoC P1: add_member must not create an ACTIVE membership without the
-- invitee's consent, and must not move the invitee's default tenant.
-- Migration 20261008090000_membership_invite_consent.sql.
begin;

-- ---------- privileges ----------
select tests.ok(
  has_function_privilege('authenticated', 'identity.accept_membership(uuid)', 'execute')
  and has_function_privilege('authenticated', 'identity.my_invitations()', 'execute'),
  'accept_membership() / my_invitations() are executable by authenticated (the API runs them as authenticated)');
select tests.ok(
  not has_function_privilege('anon', 'identity.accept_membership(uuid)', 'execute')
  and not has_function_privilege('anon', 'identity.my_invitations()', 'execute')
  and not has_function_privilege('anon', 'identity.add_member(uuid, text, text, uuid)', 'execute'),
  'anon cannot execute the invitation functions');
select tests.ok(
  pg_get_function_result('identity.my_invitations()'::regprocedure)
      = 'TABLE(membership_id uuid, tenant_id uuid, tenant_name text, branch_id uuid, role text, invited_at timestamp with time zone)',
  'my_invitations() returns exactly (membership_id, tenant_id, tenant_name, branch_id, role, invited_at)');

-- ---------- P1 before: the Beta doctor's default is Beta, and it is persisted ----------
select tests.authenticate_as('doctor@beta.example');
select tests.ok((select tenant_id from identity.my_active_context()) = '22222222-2222-4222-8222-222222222222',
  'P1: beta doctor defaults to Beta');
select tests.as_superuser();
select tests.ok(
  (select active_tenant_id from identity.user_profiles where id = '0b000000-0000-4000-8000-000000000002') = '22222222-2222-4222-8222-222222222222',
  'first resolved default tenant is persisted to user_profiles.active_tenant_id');

-- ---------- P1: Alpha admin invites the Beta doctor ----------
select tests.authenticate_as('admin@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
create temporary table p1 on commit drop as
  select identity.add_member('11111111-1111-4111-8111-111111111111', 'doctor@beta.example', 'doctor', null) as id;
grant select on p1 to public;
select tests.ok((select id from p1) is not null, 'P1: add_member returns a membership id for an existing account');
select tests.ok(
  identity.add_member('11111111-1111-4111-8111-111111111111', 'doctor@beta.example', 'nurse', null) = (select id from p1),
  'inviting again (same tenant, same tenant-wide scope) returns the same membership id (no error, no second row)');
select tests.ok(identity.add_member('11111111-1111-4111-8111-111111111111', 'nobody@nowhere.test', 'viewer', null) is null,
  'P1 enumeration: unknown email returns NULL, not an error');

select tests.as_superuser();
select tests.ok(
  (select status from identity.memberships where id = (select id from p1)) = 'invited'
  and (select count(*) from identity.memberships
       where user_id = '0b000000-0000-4000-8000-000000000002' and tenant_id = '11111111-1111-4111-8111-111111111111') = 1,
  'P1: the new membership is INVITED (exactly one row, role/branch unchanged by the repeat invite)');
select tests.ok(
  (select role = 'doctor' and branch_id is null from identity.memberships where id = (select id from p1)),
  'repeat invite did not change the pending membership');
select tests.ok(
  (select tenant_id from identity.resolve_active_context('0b000000-0000-4000-8000-000000000002')) = '22222222-2222-4222-8222-222222222222',
  'P1: the invite does not change the beta doctor''s resolved context');
set local role supabase_auth_admin;
select tests.ok(
  (identity.custom_access_token_hook('{"user_id":"0b000000-0000-4000-8000-000000000002","claims":{"role":"authenticated"}}'::jsonb)
     -> 'claims' ->> 'tenant_id') = '22222222-2222-4222-8222-222222222222',
  'P1: the access token hook still stamps Beta for the beta doctor');
reset role;

-- ---------- invited never counts for tenant context ----------
select tests.authenticate_as('doctor@beta.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.ok(not identity.has_tenant_role('11111111-1111-4111-8111-111111111111', array['doctor']),
  'invited membership does not count for has_tenant_role');
select tests.ok((select count(*) from identity.current_tenant_ids()) = 0,
  'invited membership does not count for current_tenant_ids (even with a forged Alpha claim)');
select tests.ok((select count(*) from patient.patients) = 0, 'invitee cannot read Alpha patients before accepting');
select tests.ok((select count(*) from identity.current_branch_ids('11111111-1111-4111-8111-111111111111')) = 0,
  'invited membership grants no Alpha branches');
select tests.authenticate_as('doctor@beta.example');
select tests.ok(not exists (select 1 from identity.my_memberships() where tenant_id = '11111111-1111-4111-8111-111111111111'),
  'invited membership is not listed by my_memberships()');
select tests.throws_ok($$select identity.set_active_context('11111111-1111-4111-8111-111111111111')$$, '42501',
  'cannot switch the active context to a tenant you are only invited to');

-- ---------- admins cannot see, activate or forge ----------
select tests.authenticate_as('admin@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.ok(not exists (select 1 from identity.memberships where id = (select id from p1)),
  'admin cannot see the pending invitation (RLS)');
select tests.ok(not exists (select 1 from identity.user_profiles where id = '0b000000-0000-4000-8000-000000000002'),
  'admin cannot see the invitee''s profile (is_admin_of_member excludes invited)');
select tests.ok(not identity.is_admin_of_member('0b000000-0000-4000-8000-000000000002'),
  'is_admin_of_member() is false for an invitee');
select tests.ok(
  tests.affected_rows(format($$update identity.memberships set status = 'active' where id = %L$$, (select id from p1))) = 0,
  'admin direct UPDATE invited -> active affects 0 rows');
select tests.ok(
  tests.affected_rows(format($$delete from identity.memberships where id = %L$$, (select id from p1))) = 0,
  'admin cannot delete the pending invitation either (hidden)');
select tests.throws_ok(
  $$insert into identity.memberships (tenant_id, user_id, role, status)
    values ('11111111-1111-4111-8111-111111111111', '0c000000-0000-4000-8000-000000000001', 'viewer', 'active')$$,
  '42501', 'admin cannot INSERT an active membership for another user (bypassing add_member)');
select tests.ok(
  tests.affected_rows($$insert into identity.memberships (tenant_id, user_id, branch_id, role)
    values ('11111111-1111-4111-8111-111111111111', '0d000000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000001', 'viewer')$$) = 1,
  'admin INSERT relying on the column default creates an INVITED row (default is invited since 20261009090000)');
select tests.throws_ok(
  $$update identity.memberships set user_id = '0c000000-0000-4000-8000-000000000001'
     where user_id = '0a000000-0000-4000-8000-000000000002' and tenant_id = '11111111-1111-4111-8111-111111111111'$$,
  '42501', 'admin cannot re-point an existing active membership at another user (user_id immutable)');
select tests.throws_ok(
  $$update identity.memberships set status = 'invited'
     where user_id = '0a000000-0000-4000-8000-000000000002' and tenant_id = '11111111-1111-4111-8111-111111111111'$$,
  '42501', 'admin cannot move an active membership back to invited');
select tests.throws_ok(format($$select identity.accept_membership(%L)$$, (select id from p1)), 'P0002',
  'admin cannot accept an invitation on the invitee''s behalf');

-- Privileged paths are blocked by the trigger too (only accept_membership may activate).
select tests.as_superuser();
select tests.throws_ok(format($$update identity.memberships set status = 'active' where id = %L$$, (select id from p1)), '42501',
  'owner/superuser UPDATE invited -> active is rejected by the consent trigger');
set local role service_role;
select tests.throws_ok(format($$update identity.memberships set status = 'active' where id = %L$$, (select id from p1)), '42501',
  'service_role UPDATE invited -> active is rejected by the consent trigger');
reset role;
-- Even with the accept flag forged for this row, the actor must be the invitee.
select set_config('identity.accepting_membership', (select id::text from p1), true);
select set_config('request.jwt.claims', '{"sub":"0a000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select tests.throws_ok(format($$update identity.memberships set status = 'active' where id = %L$$, (select id from p1)), '42501',
  'a forged accept flag does not help anyone but the invitee');
select set_config('identity.accepting_membership', '', true);
select tests.as_superuser();

-- ---------- only the invitee can accept ----------
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(format($$select identity.accept_membership(%L)$$, (select id from p1)), 'P0002',
  'another user cannot accept the invitation');
select tests.authenticate_as('outsider@example.test');
select tests.ok((select count(*) from identity.my_invitations()) = 0, 'a signed-in user with no tenant can call my_invitations() (empty)');
select tests.throws_ok(format($$select identity.accept_membership(%L)$$, gen_random_uuid()), 'P0002',
  'accepting an unknown id raises P0002');

select tests.authenticate_as('doctor@beta.example');
select tests.ok(
  (select count(*) = 1 and bool_and(membership_id = (select id from p1) and tenant_id = '11111111-1111-4111-8111-111111111111'
          and tenant_name = 'Demo Alpha Hospital (synthetic)' and branch_id is null and role = 'doctor' and invited_at is not null)
   from identity.my_invitations()),
  'invitee sees the invitation in my_invitations()');
select identity.accept_membership((select id from p1));
select tests.ok(not exists (select 1 from identity.my_invitations()), 'accepted invitation is no longer pending');
select tests.throws_ok(format($$select identity.accept_membership(%L)$$, (select id from p1)), 'P0002',
  'accepting twice raises P0002');
select tests.ok((select tenant_id from identity.my_active_context()) = '22222222-2222-4222-8222-222222222222',
  'P1 after accepting: the default tenant is still Beta (persisted, and older membership wins)');
select tests.authenticate_as('doctor@beta.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.ok((select count(*) from patient.patients) = 4, 'after accepting, the doctor can work in Alpha when it is chosen');

select tests.authenticate_as('admin@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.ok(exists (select 1 from identity.memberships where id = (select id from p1) and status = 'active'),
  'after acceptance the admin sees the active membership');
select tests.ok(
  tests.affected_rows(format($$update identity.memberships set status = 'suspended' where id = %L$$, (select id from p1))) = 1,
  'admin can suspend an accepted membership');
select tests.ok(
  tests.affected_rows(format($$update identity.memberships set status = 'active' where id = %L$$, (select id from p1))) = 1,
  'admin can reactivate a suspended (previously accepted) membership');

-- Suspended tenants: invitations are hidden and cannot be accepted.
select tests.authenticate_as('admin@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
create temporary table p1b on commit drop as
  select identity.add_member('11111111-1111-4111-8111-111111111111', 'admin@beta.example', 'viewer') as id;
grant select on p1b to public;
select tests.as_superuser();
update identity.tenants set status = 'suspended' where id = '11111111-1111-4111-8111-111111111111';
select tests.authenticate_as('admin@beta.example');
select tests.ok(not exists (select 1 from identity.my_invitations()), 'invitations of a suspended tenant are hidden');
select tests.throws_ok(format($$select identity.accept_membership(%L)$$, (select id from p1b)), 'P0002',
  'invitations of a suspended tenant cannot be accepted');
select tests.as_superuser();
update identity.tenants set status = 'active' where id = '11111111-1111-4111-8111-111111111111';

-- ---------- default tenant = oldest membership, not tenant name ----------
select tests.as_superuser();
insert into auth.users (id, email) values ('0f000000-0000-4000-8000-000000000001', 'ordering@shared.example');
set local session_replication_role = replica; -- setup only: keep the explicit created_at values
insert into identity.memberships (tenant_id, user_id, role, status, created_at) values
  ('22222222-2222-4222-8222-222222222222', '0f000000-0000-4000-8000-000000000001', 'doctor', 'active', now() - interval '1 day'),
  ('11111111-1111-4111-8111-111111111111', '0f000000-0000-4000-8000-000000000001', 'doctor', 'active', now());
set local session_replication_role = origin;
set local role supabase_auth_admin;
select tests.ok(
  (identity.custom_access_token_hook('{"user_id":"0f000000-0000-4000-8000-000000000001","claims":{}}'::jsonb)
     -> 'claims' ->> 'tenant_id') = '22222222-2222-4222-8222-222222222222',
  'default tenant is the OLDEST membership (Beta), not the first by name (Alpha)');
reset role;
select tests.ok(
  (select active_tenant_id from identity.user_profiles where id = '0f000000-0000-4000-8000-000000000001') = '22222222-2222-4222-8222-222222222222',
  'the hook persists the resolved default (creating the profile if missing)');

select tests.ok(
  (select count(*) from pg_trigger where tgrelid = 'identity.memberships'::regclass and tgname = 'memberships_consent' and not tgisinternal) = 1,
  'consent trigger is installed on identity.memberships');

rollback;
