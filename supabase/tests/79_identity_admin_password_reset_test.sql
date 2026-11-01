-- Admin password reset (20261101003000): tenant-scoped, no platform admins, not yourself, rate
-- limited, sessions revoked, old password unusable, link emailed off the outbox payload, audited.
begin;

select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e790000-0000-4000-8000-000000000001', 'zz-qa-reset-op@medicore.example', 'authenticated', 'authenticated')
on conflict (id) do nothing;
select identity.grant_platform_admin('zz-qa-reset-op@medicore.example');
-- The platform admin also works at Alpha so an Alpha admin could try to reset them.
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0e790000-0000-4000-8000-000000000001', null, 'doctor', 'active');
update auth.users set encrypted_password = 'old-hash'
 where id = '0a000000-0000-4000-8000-000000000002';
insert into auth.sessions (id, user_id) values ('0e790000-0000-4000-8000-0000000000aa', '0a000000-0000-4000-8000-000000000002');
insert into auth.refresh_tokens (token, user_id, session_id)
values ('zz-qa-rt', '0a000000-0000-4000-8000-000000000002', '0e790000-0000-4000-8000-0000000000aa');

create temp table ids on commit drop as select
  (select id from identity.memberships where user_id = '0a000000-0000-4000-8000-000000000002' and tenant_id = '11111111-1111-4111-8111-111111111111') as recept,
  (select id from identity.memberships where user_id = '0a000000-0000-4000-8000-000000000001' and tenant_id = '11111111-1111-4111-8111-111111111111') as self,
  (select id from identity.memberships where user_id = '0e790000-0000-4000-8000-000000000001') as platform,
  (select id from identity.memberships where user_id = '0b000000-0000-4000-8000-000000000002') as beta_doctor;
grant select on ids to public;

select tests.ok(
  has_function_privilege('authenticated', 'identity.admin_reset_member_password(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'identity.admin_reset_member_password(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'identity.consume_password_reset(text)', 'execute')
  and not has_function_privilege('anon', 'identity.consume_password_reset(text)', 'execute')
  and has_function_privilege('hms_mailer', 'identity.consume_password_reset(text)', 'execute')
  and not has_table_privilege('authenticated', 'identity.password_resets', 'select'),
  'reset is callable by signed-in users only (checked inside), consume by the mailer only');

-- A non-admin of Alpha (receptionist) is refused.
select tests.authenticate_as('lab@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.throws_ok(
  $$select identity.admin_reset_member_password('11111111-1111-4111-8111-111111111111', (select recept from ids))$$,
  '42501', 'a non-admin cannot reset passwords');

-- Alpha admin.
select tests.authenticate_as('admin@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.throws_ok(
  $$select identity.admin_reset_member_password('22222222-2222-4222-8222-222222222222', (select beta_doctor from ids))$$,
  '42501', 'an admin cannot act on a hospital they do not administer');
select tests.throws_ok(
  $$select identity.admin_reset_member_password('11111111-1111-4111-8111-111111111111', (select beta_doctor from ids))$$,
  '42501', 'a member of another hospital is refused (cross-tenant)');
select tests.throws_ok(
  $$select identity.admin_reset_member_password('11111111-1111-4111-8111-111111111111', (select self from ids))$$,
  '55000', 'an admin cannot reset their own password here');
select tests.throws_ok(
  $$select identity.admin_reset_member_password('11111111-1111-4111-8111-111111111111', (select platform from ids))$$,
  '42501', 'a platform admin cannot be reset by a hospital admin');
select tests.throws_ok(
  $$select identity.admin_reset_member_password('11111111-1111-4111-8111-111111111111', gen_random_uuid())$$,
  'P0002', 'an unknown membership is not found');

select tests.ok(
  identity.admin_reset_member_password('11111111-1111-4111-8111-111111111111', (select recept from ids)) > now(),
  'the admin resets a staff member of their own hospital');

select tests.as_superuser();
select tests.ok(
  (select count(*) = 0 from auth.sessions where user_id = '0a000000-0000-4000-8000-000000000002')
  and (select count(*) = 0 from auth.refresh_tokens where user_id = '0a000000-0000-4000-8000-000000000002'),
  'every session and refresh token of the target is revoked');
select tests.ok(
  (select encrypted_password <> 'old-hash' and encrypted_password like '$2%'
          and (raw_user_meta_data ->> 'needs_password')::boolean
     from auth.users where id = '0a000000-0000-4000-8000-000000000002'),
  'the old password is replaced by an unknown bcrypt hash and a new password is required');
select tests.ok(
  (select count(*) = 1 and bool_and(o.payload::text not like '%@%')
          and bool_and(o.payload::text not like '%' || (p.variables ->> 'token') || '%')
          and bool_and(p.variables ->> 'token' ~ '^[0-9a-f]{64}$')
     from messaging.outbox o
     join identity.pending_emails p on p.id = (o.payload ->> 'pending_email_id')::uuid
    where o.event_type = 'email.password_reset'),
  'the link is emailed and the token stays off the outbox payload');
select tests.ok(
  (select count(*) = 1
          and bool_and(changed_by = '0a000000-0000-4000-8000-000000000001')
          and bool_and(new_data ->> 'target_user_id' = '0a000000-0000-4000-8000-000000000002')
          and bool_and(new_data::text not like '%token%' or new_data ? 'event')
          and bool_and(not (new_data ? 'token'))
     from audit.audit_log where table_name = 'password_resets' and new_data ->> 'event' = 'admin_password_reset'),
  'the audit log records who reset whom, without the token');

create temp table tok on commit drop as
  select variables ->> 'token' as token from identity.pending_emails where template_key = 'password_reset';
grant select on tok to public;

set local role hms_mailer;
select tests.ok(identity.consume_password_reset((select token from tok)) is not null, 'the link resolves to the account once');
select tests.throws_ok($$select identity.consume_password_reset((select token from tok))$$, 'P0002', 'a used link is refused');
select tests.throws_ok($$select identity.consume_password_reset('not-a-token')$$, 'P0002', 'a malformed link is refused');
reset role;

-- Rate limit: three resets per target per hour.
select tests.authenticate_as('admin@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select identity.admin_reset_member_password('11111111-1111-4111-8111-111111111111', (select recept from ids));
select identity.admin_reset_member_password('11111111-1111-4111-8111-111111111111', (select recept from ids));
select tests.throws_ok(
  $$select identity.admin_reset_member_password('11111111-1111-4111-8111-111111111111', (select recept from ids))$$,
  '54000', 'a fourth reset of the same user within an hour is rate limited');

rollback;
