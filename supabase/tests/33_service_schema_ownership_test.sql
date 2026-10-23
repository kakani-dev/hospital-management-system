-- Service roles can read only their own schema. Cross-schema data is _v1 EXECUTE, not tables.
-- Migration 20261022140000_platform_service_schema_ownership.sql. ADR 0002.
begin;

select tests.ok(
  not pg_has_role('hms_identity_login', 'authenticated', 'member')
  and not pg_has_role('hms_patients_login', 'authenticated', 'member')
  and not pg_has_role('hms_scheduling_login', 'authenticated', 'member')
  and not pg_has_role('hms_billing_login', 'authenticated', 'member')
  and not pg_has_role('hms_inventory_login', 'authenticated', 'member'),
  'service logins are not members of authenticated');

select tests.ok(
  pg_has_role('hms_identity_login', 'hms_svc_identity', 'member')
  and pg_has_role('hms_patients_login', 'hms_svc_patients', 'member')
  and pg_has_role('hms_scheduling_login', 'hms_svc_scheduling', 'member')
  and pg_has_role('hms_billing_login', 'hms_svc_billing', 'member')
  and pg_has_role('hms_inventory_login', 'hms_svc_inventory', 'member'),
  'each login is a member of its own service role');

select tests.ok(pg_has_role('hms_api_login', 'authenticated', 'member'),
  'legacy hms_api_login can still become authenticated');

select tests.ok(
  has_table_privilege('hms_svc_patients', 'patient.patients', 'select')
  and not has_table_privilege('hms_svc_patients', 'appointment.appointments', 'select')
  and not has_table_privilege('hms_svc_patients', 'identity.tenants', 'select')
  and not has_table_privilege('hms_svc_patients', 'identity.branches', 'select'),
  'patients role: select on patient.patients only');

select tests.ok(
  has_table_privilege('hms_svc_scheduling', 'appointment.appointments', 'select')
  and not has_table_privilege('hms_svc_scheduling', 'patient.patients', 'select')
  and not has_table_privilege('hms_svc_scheduling', 'identity.branches', 'select'),
  'scheduling role: select on appointment.appointments only');

select tests.ok(
  has_table_privilege('hms_svc_identity', 'identity.tenants', 'select')
  and not has_table_privilege('hms_svc_identity', 'patient.patients', 'select')
  and not has_table_privilege('hms_svc_identity', 'appointment.appointments', 'select'),
  'identity role: select on identity.tenants only');

select tests.ok(
  has_function_privilege('hms_svc_patients', 'appointment.patient_last_booked_v1(uuid, integer)', 'execute')
  and has_function_privilege('hms_svc_patients', 'identity.branch_exists_v1(uuid, uuid)', 'execute')
  and has_function_privilege('hms_svc_patients', 'identity.tenant_default_country_code_v1(uuid)', 'execute')
  and not has_function_privilege('hms_svc_patients', 'appointment.reassign_patient_for_merge(uuid, uuid, uuid)', 'execute'),
  'patients role executes approved contracts and not scheduling owner functions');

select tests.ok(
  has_function_privilege('hms_svc_scheduling', 'patient.patient_summary_v1(uuid, uuid[])', 'execute')
  and has_function_privilege('hms_svc_scheduling', 'identity.my_tenant_grant_v1(uuid)', 'execute')
  and has_function_privilege('hms_svc_identity', 'identity.my_active_context()', 'execute')
  and has_function_privilege('hms_svc_patients', 'auth.uid()', 'execute')
  and has_function_privilege('hms_svc_billing', 'appointment.appointment_billing_ref_v1(uuid, uuid)', 'execute')
  and has_function_privilege('hms_svc_billing', 'identity.caller_roles_v1(uuid)', 'execute')
  and has_function_privilege('hms_svc_billing', 'identity.my_tenant_grant_v1(uuid)', 'execute')
  and has_function_privilege('hms_svc_billing', 'identity.my_active_context()', 'execute')
  and has_function_privilege('hms_svc_inventory', 'identity.branch_exists_v1(uuid, uuid)', 'execute')
  and has_function_privilege('hms_svc_inventory', 'identity.my_active_context()', 'execute')
  and not has_function_privilege('hms_svc_scheduling', 'billing.finalize_bill(uuid, uuid)', 'execute')
  and not has_function_privilege('hms_svc_billing', 'inventory.fefo_pick_v1(uuid, uuid, uuid, bigint)', 'execute')
  and not has_function_privilege('hms_svc_inventory', 'billing.finalize_bill(uuid, uuid)', 'execute'),
  'published identity/patient functions and auth.uid() are executable by the service roles');

-- Live session: receptionist as the patients login, then the patients session role.
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated', 'email', 'reception@alpha.example')::text,
  true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000002', true);
set local role hms_patients_login;
set local role hms_svc_patients;

select tests.ok((select count(*) from patient.patients) > 0,
  'patients session role reads its own rows under RLS');
select tests.ok(identity.branch_exists_v1('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001'),
  'patients session role resolves a live branch through branch_exists_v1');
select tests.throws_ok(
  'select count(*) from appointment.appointments',
  '42501',
  'patients session role cannot select appointment.appointments');
select tests.throws_ok(
  'select count(*) from identity.branches',
  '42501',
  'patients session role cannot select identity.branches');
-- SET ROLE is limited by the session user. A superuser session can assume any role, so this
-- check has to run with the login as the session user (what the service process actually is).
select tests.as_superuser();
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated', 'email', 'reception@alpha.example')::text,
  true);
set local session authorization hms_patients_login;
set local role hms_svc_patients;
select tests.throws_ok(
  'set local role authenticated',
  '42501',
  'patients session role cannot become authenticated');
reset session authorization;

select tests.as_superuser();
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text,
  true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
set local role hms_scheduling_login;
set local role hms_svc_scheduling;

select tests.ok((select count(*) from appointment.appointments) >= 0,
  'scheduling session role can query its own table');
select tests.ok(
  (select count(*) from patient.patient_summary_v1(
    '11111111-1111-4111-8111-111111111111',
    array['aa000000-0000-4000-8000-000000000001'::uuid])) = 1,
  'scheduling reads a patient summary through patient_summary_v1');
select tests.throws_ok(
  'select count(*) from patient.patients',
  '42501',
  'scheduling session role cannot select patient.patients');

select tests.as_superuser();

rollback;
