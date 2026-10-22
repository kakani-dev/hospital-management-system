-- Invite sign-in codes: hashed, emailed without the code in the outbox payload, one success burns the code.
-- Migration 20261022120000_invite_sign_in_codes.sql.
begin;

select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e320000-0000-4000-8000-000000000001', 'op-code@medicore.example', 'authenticated', 'authenticated'),
  ('0e320000-0000-4000-8000-000000000002', 'code@email-test.example', 'authenticated', 'authenticated');
select identity.grant_platform_admin('op-code@medicore.example');

select tests.ok(
  not has_function_privilege('anon', 'identity.issue_invite_sign_in_code(text)', 'execute')
  and not has_function_privilege('anon', 'identity.consume_invite_sign_in_code(text, text)', 'execute')
  and not has_function_privilege('authenticated', 'identity.issue_invite_sign_in_code(text)', 'execute')
  and has_function_privilege('hms_mailer', 'identity.issue_invite_sign_in_code(text)', 'execute')
  and has_function_privilege('hms_mailer', 'identity.consume_invite_sign_in_code(text, text)', 'execute')
  and not has_table_privilege('anon', 'identity.email_sign_in_codes', 'select')
  and not has_table_privilege('hms_mailer', 'identity.email_sign_in_codes', 'select'),
  'sign-in codes are callable by the mailer only, and the table is not readable by clients');

select tests.as_anon();
select tests.ok(identity.submit_tenant_signup(
  'Code Test Hospital', 'UTC', 'Code Contact', 'code@email-test.example', '+1 555 0199', 'NYC', 'src-code') is not null,
  'a registration for the code test is accepted');

select tests.authenticate_as('op-code@medicore.example');
create temporary table t_code_appr on commit drop as
  select * from identity.platform_approve_signup(
    (select id from identity.platform_list_signups('pending') where hospital_name = 'Code Test Hospital'),
    'code-test');
grant select on t_code_appr to public;

select tests.as_superuser();
create temporary table t_code_token on commit drop as
  select (p.variables ->> 'token') as token, p.invite_link_id
    from identity.pending_emails p
   where p.template_key = 'signup_approved' and p.recipient = 'code@email-test.example' and p.redacted_on is null;
grant select on t_code_token to public;
select tests.ok((select length(token) = 64 from t_code_token), 'approval stored the invite token on pending_emails only');

select identity.issue_invite_sign_in_code((select token from t_code_token));
select tests.ok(
  (select count(*) = 1
     and bool_and(o.payload::text not like '%@%')
     and bool_and(o.payload ->> 'template_key' = 'sign_in_code')
     and bool_and(o.payload::text not like '%' || (p.variables ->> 'code') || '%')
     and bool_and(o.payload::text not like '%' || (select token from t_code_token) || '%')
     and bool_and(p.variables ->> 'code' ~ '^[0-9]{6}$')
     and bool_and(p.recipient = 'code@email-test.example')
     and bool_and(octet_length(c.code_hash) = 32)
     and bool_and(c.consumed_on is null)
    from messaging.outbox o
    join identity.pending_emails p on p.id = (o.payload ->> 'pending_email_id')::uuid
    join identity.email_sign_in_codes c on c.id = o.aggregate_id
   where o.event_type = 'email.sign_in_code' and p.invite_link_id = (select invite_link_id from t_code_token)),
  'the code and token stay off the outbox payload and the hash is stored');

select tests.ok(
  identity.consume_invite_sign_in_code((select token from t_code_token), '000000') is null,
  'a wrong code is rejected without rolling the attempt back');
select tests.ok(
  (select failed_attempts = 1 and consumed_on is null from identity.email_sign_in_codes
    where invite_link_id = (select invite_link_id from t_code_token) and consumed_on is null),
  'one mismatch is counted and the code stays usable');
select tests.ok(
  identity.consume_invite_sign_in_code((select token from t_code_token),
    (select p.variables ->> 'code' from identity.pending_emails p
      where p.template_key = 'sign_in_code' and p.invite_link_id = (select invite_link_id from t_code_token)))
  = 'code@email-test.example',
  'the matching code returns the invited email');
select tests.throws_ok(
  format('select identity.consume_invite_sign_in_code(%L, %L)', (select token from t_code_token),
    (select p.variables ->> 'code' from identity.pending_emails p
      where p.template_key = 'sign_in_code' and p.invite_link_id = (select invite_link_id from t_code_token)
        and p.redacted_on is null
      order by p.created_on limit 1)),
  '42501', 'the same code cannot be used twice');

select identity.issue_invite_sign_in_code((select token from t_code_token));
-- now() is stable for the whole transaction, so created_on does not order the rows.
create temporary table t_burn on commit drop as
  select id from identity.email_sign_in_codes
   where invite_link_id = (select invite_link_id from t_code_token) and consumed_on is null;
select identity.consume_invite_sign_in_code((select token from t_code_token), '111111');
select identity.consume_invite_sign_in_code((select token from t_code_token), '111111');
select identity.consume_invite_sign_in_code((select token from t_code_token), '111111');
select identity.consume_invite_sign_in_code((select token from t_code_token), '111111');
select tests.ok(
  identity.consume_invite_sign_in_code((select token from t_code_token), '111111') is null,
  'the fifth mismatch is still rejected');
select tests.ok(
  (select count(*) = 1 from t_burn)
  and (select failed_attempts = 5 and consumed_on is not null from identity.email_sign_in_codes
        where id = (select id from t_burn)),
  'five mismatches burn the code');
select tests.throws_ok(
  format('select identity.consume_invite_sign_in_code(%L, %L)', (select token from t_code_token), '111111'),
  '42501', 'a burned code is rejected before another attempt is counted');

set local session authorization hms_identity_login;
set local role hms_mailer;
select tests.ok(identity.issue_invite_sign_in_code((select token from t_code_token)) > now(),
  'the identity login, as hms_mailer, can issue another code');
reset role;
reset session authorization;

select tests.as_superuser();
select identity.suppress_emails_for_link((select invite_link_id from t_code_token));
select tests.ok(
  not exists (select 1 from identity.email_sign_in_codes
    where invite_link_id = (select invite_link_id from t_code_token) and consumed_on is null)
  and not exists (select 1 from identity.pending_emails
    where invite_link_id = (select invite_link_id from t_code_token) and redacted_on is null),
  'suppressing the invite burns outstanding codes and redacts unsent mail');

rollback;
