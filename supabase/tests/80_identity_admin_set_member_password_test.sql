-- Admin sets a staff member's password (20261101004000): policy, tenant-scoped, no platform admins,
-- not yourself, bcrypt stored, must change at next sign-in, sessions revoked, audited without the password.
begin;

select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e800000-0000-4000-8000-000000000001', 'zz-qa-set-op@medicore.example', 'authenticated', 'authenticated')
on conflict (id) do nothing;
select identity.grant_platform_admin('zz-qa-set-op@medicore.example');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0e800000-0000-4000-8000-000000000001', null, 'doctor', 'active');
update auth.users set encrypted_password = 'old-hash' where id = '0a000000-0000-4000-8000-000000000003';
insert into auth.sessions (id, user_id) values ('0e800000-0000-4000-8000-0000000000aa', '0a000000-0000-4000-8000-000000000003');
insert into auth.refresh_tokens (token, user_id, session_id)
values ('zz-qa-rt-80', '0a000000-0000-4000-8000-000000000003', '0e800000-0000-4000-8000-0000000000aa');

create temp table ids on commit drop as select
  (select id from identity.memberships where user_id = '0a000000-0000-4000-8000-000000000003' and tenant_id = '11111111-1111-4111-8111-111111111111') as lab,
  (select id from identity.memberships where user_id = '0a000000-0000-4000-8000-000000000001' and tenant_id = '11111111-1111-4111-8111-111111111111') as self,
  (select id from identity.memberships where user_id = '0e800000-0000-4000-8000-000000000001') as platform,
  (select id from identity.memberships where user_id = '0b000000-0000-4000-8000-000000000002') as beta_doctor;
grant select on ids to public;

select tests.ok(
  has_function_privilege('authenticated', 'identity.admin_set_member_password(uuid, uuid, text)', 'execute')
  and not has_function_privilege('anon', 'identity.admin_set_member_password(uuid, uuid, text)', 'execute'),
  'set-password is callable by signed-in users only (checked inside)');

select tests.authenticate_as('reception@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.throws_ok($$select identity.admin_set_member_password('11111111-1111-4111-8111-111111111111', (select lab from ids), 'Synthetic123x')$$,
  '42501', 'a non-admin cannot set passwords');

select tests.authenticate_as('doctor@beta.example', '{"tenant_id": "22222222-2222-4222-8222-222222222222"}');
select tests.throws_ok($$select identity.admin_set_member_password('11111111-1111-4111-8111-111111111111', (select lab from ids), 'Synthetic123x')$$,
  '42501', 'someone outside Alpha cannot act for Alpha');

select tests.authenticate_as('admin@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.throws_ok($$select identity.admin_set_member_password('11111111-1111-4111-8111-111111111111', (select beta_doctor from ids), 'Synthetic123x')$$,
  '42501', 'an Alpha admin cannot set the password of a Beta member');
select tests.throws_ok($$select identity.admin_set_member_password('11111111-1111-4111-8111-111111111111', (select self from ids), 'Synthetic123x')$$,
  '55000', 'not your own account');
select tests.throws_ok($$select identity.admin_set_member_password('11111111-1111-4111-8111-111111111111', (select platform from ids), 'Synthetic123x')$$,
  '42501', 'not a platform admin');
select tests.throws_ok($$select identity.admin_set_member_password('11111111-1111-4111-8111-111111111111', (select lab from ids), 'short1')$$,
  '22023', 'too short is refused');
select tests.throws_ok($$select identity.admin_set_member_password('11111111-1111-4111-8111-111111111111', (select lab from ids), 'onlyletterspassword')$$,
  '22023', 'letters only is refused');
select identity.admin_set_member_password('11111111-1111-4111-8111-111111111111', (select lab from ids), 'Synthetic123x');

select tests.as_superuser();
select tests.ok(
  (select encrypted_password like '$2%' and encrypted_password <> 'old-hash' and encrypted_password not like '%Synthetic123x%'
          and (raw_user_meta_data ->> 'needs_password')::boolean
     from auth.users where id = '0a000000-0000-4000-8000-000000000003'),
  'the new password is stored as bcrypt and must be changed at next sign-in');
select tests.ok(
  not exists (select 1 from auth.sessions where user_id = '0a000000-0000-4000-8000-000000000003')
  and not exists (select 1 from auth.refresh_tokens where user_id = '0a000000-0000-4000-8000-000000000003'),
  'all sessions are revoked');
select tests.ok(
  (select count(*) = 1 and bool_and(new_data ->> 'event' = 'admin_password_set' and new_data::text not like '%Synthetic123x%'
                                    and changed_by = '0a000000-0000-4000-8000-000000000001')
     from audit.audit_log where table_name = 'password_resets' and new_data ->> 'target_user_id' = '0a000000-0000-4000-8000-000000000003'),
  'audited with the actor and without the password');
select tests.ok(
  not exists (select 1 from identity.pending_emails where recipient like 'lab@alpha%' and template_key = 'password_reset'),
  'no email is sent for a direct set');

rollback;
