-- #320: changing your own password records a session cutoff and revokes
-- refresh tokens / sessions the same way an admin reset does.
begin;

select tests.as_superuser();

insert into auth.users (id, email, role, aud) values
  ('0a320000-0000-4000-8000-000000000001', 'zz-qa-own-pw@synthetic.example', 'authenticated', 'authenticated');
insert into identity.memberships (tenant_id, user_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0a320000-0000-4000-8000-000000000001', 'nurse', 'active');
insert into auth.sessions (id, user_id) values
  ('0a320000-0000-4000-8000-0000000000aa', '0a320000-0000-4000-8000-000000000001');
insert into auth.refresh_tokens (token, user_id, session_id) values
  ('zz-qa-rt-85', '0a320000-0000-4000-8000-000000000001', '0a320000-0000-4000-8000-0000000000aa');

select tests.authenticate_as(
  'zz-qa-own-pw@synthetic.example',
  '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');

select tests.throws_ok($$select identity.change_own_password('short1')$$, '22023', 'weak passwords are refused before any cutoff');

select tests.as_superuser();
select tests.ok(
  exists (select 1 from auth.refresh_tokens where token = 'zz-qa-rt-85')
  and exists (select 1 from auth.sessions where id = '0a320000-0000-4000-8000-0000000000aa')
  and not exists (select 1 from identity.user_security where user_id = '0a320000-0000-4000-8000-000000000001'),
  'a rejected password leaves sessions and does not write a cutoff');

select tests.authenticate_as(
  'zz-qa-own-pw@synthetic.example',
  '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');

create temp table own_pw_result on commit drop as
  select identity.change_own_password('ZzOwnChoice2026') as r;

select tests.as_superuser();
select tests.ok(
  (select
     r ->> 'email' = 'zz-qa-own-pw@synthetic.example'
     and (r ->> 'sessionsInvalidatedEpoch')::bigint = pg_catalog.floor(extract(epoch from s.sessions_invalidated_on))::bigint
   from own_pw_result
   join identity.user_security s on s.user_id = '0a320000-0000-4000-8000-000000000001'),
  'returns the account email and the floored cutoff epoch');

select tests.ok(
  (select not must_change_password and sessions_invalidated_on is not null
     from identity.user_security where user_id = '0a320000-0000-4000-8000-000000000001'),
  'changing it records a session cutoff and clears the must-change flag');
select tests.ok(
  not exists (select 1 from auth.refresh_tokens where user_id = '0a320000-0000-4000-8000-000000000001')
  and not exists (select 1 from auth.sessions where user_id = '0a320000-0000-4000-8000-000000000001'),
  'all refresh tokens and sessions are revoked');

rollback;
