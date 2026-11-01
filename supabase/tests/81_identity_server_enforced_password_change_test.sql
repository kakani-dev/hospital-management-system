-- Server-enforced must-change-password (20261101030000): flag server-owned, set by an admin reset,
-- cleared only by change_own_password, and sessions_invalidated_on recorded for token revocation.
begin;

select tests.ok(
  not has_table_privilege('authenticated', 'identity.user_security', 'select')
  and not has_table_privilege('authenticated', 'identity.user_security', 'update'),
  'signed-in users cannot read or write the flag table directly');

select tests.authenticate_as('admin@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select identity.admin_set_member_password('11111111-1111-4111-8111-111111111111',
  (select id from identity.memberships where user_id = '0a000000-0000-4000-8000-000000000003' and tenant_id = '11111111-1111-4111-8111-111111111111'),
  'Synthetic123x');

select tests.as_superuser();
select tests.ok(
  (select must_change_password and sessions_invalidated_on is not null from identity.user_security where user_id = '0a000000-0000-4000-8000-000000000003')
  and (select (raw_app_meta_data ->> 'must_change_password')::boolean from auth.users where id = '0a000000-0000-4000-8000-000000000003'),
  'an admin reset sets the server flag (table + app metadata) and the revocation time');

select tests.authenticate_as('lab@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.ok((select must_change_password from identity.my_password_state()), 'the user sees they must change it');
select tests.throws_ok($$select identity.change_own_password('short1')$$, '22023', 'weak passwords are refused');
select identity.change_own_password('ZzOwnChoice2026');
select tests.ok(not (select must_change_password from identity.my_password_state()), 'changing it clears the flag');

select tests.as_superuser();
select tests.ok(
  (select raw_app_meta_data -> 'must_change_password' is null from auth.users where id = '0a000000-0000-4000-8000-000000000003'),
  'app metadata flag removed');

rollback;
