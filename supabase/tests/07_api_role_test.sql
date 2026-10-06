-- The API's dedicated role: no direct privileges, may only act through authenticated/anon (RLS).
begin;

select tests.ok(
  (select not rolcanlogin and not rolinherit and not rolsuper and not rolbypassrls from pg_roles where rolname = 'hms_api'),
  'hms_api is NOLOGIN, NOINHERIT, not superuser, no BYPASSRLS');
select tests.ok(pg_has_role('hms_api', 'authenticated', 'MEMBER') and not pg_has_role('hms_api', 'service_role', 'MEMBER')
  and not pg_has_role('hms_api', 'postgres', 'MEMBER') and not pg_has_role('hms_api', 'supabase_auth_admin', 'MEMBER'),
  'hms_api can switch to authenticated but is not a member of service_role/postgres/supabase_auth_admin');
select tests.ok(not has_table_privilege('hms_api', 'patient.patients', 'select'),
  'hms_api has no direct SELECT on patients (NOINHERIT)');

set local role hms_api;
select tests.throws_ok($$select count(*) from patient.patients$$, '42501',
  'a query without switching role is denied (fail closed)');
-- NOTE: SET ROLE is authorized against the SESSION user (postgres here), so escalation from the
-- real login role is tested in backend/tests/Hms.DatabaseTests (connects as hms_api_login).

-- What the API does per transaction:
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"0a000000-0000-4000-8000-000000000002","role":"authenticated","tenant_id":"11111111-1111-4111-8111-111111111111"}', true);
select tests.ok((select count(*) from patient.patients) = 4, 'via authenticated + claims the receptionist sees the 4 Alpha patients');
select tests.ok(not exists (select 1 from patient.patients where tenant_id = '22222222-2222-4222-8222-222222222222'),
  'RLS blocks Beta rows for API traffic even with no app-level WHERE clause');

reset role;
select tests.ok(
  (select rolcanlogin and not rolsuper and not rolbypassrls from pg_roles where rolname = 'hms_api_login')
  and pg_has_role('hms_api_login', 'hms_api', 'MEMBER'),
  'local login role hms_api_login is a plain login role granted hms_api');

rollback;
