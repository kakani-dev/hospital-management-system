-- DB re-review of PR #4 (R3-R6, N4, N5): migration 20261012090200 plus the R4/R6 changes to the
-- published v1 surface. R1/R2 are in 17/18, N3 and the R5 flow in 19.
begin;

-- ============================================== R3: no raw cross-schema table reads ==
select tests.ok(
  not exists (
    select 1
    from pg_proc p join pg_namespace fn on fn.oid = p.pronamespace
    join pg_class c on c.relkind in ('r', 'p', 'v') join pg_namespace tn on tn.oid = c.relnamespace
    where fn.nspname in ('identity', 'patient', 'appointment', 'messaging', 'audit')
      and tn.nspname in ('identity', 'patient', 'appointment', 'messaging', 'audit')
      and tn.nspname <> fn.nspname
      and p.prosrc ~ (tn.nspname || '\.' || c.relname || '\M')),
  'R3: no function body reads another schema''s table (catalog scan over all five schemas)');
select tests.ok(
  (select prosrc ~ 'patient\.patient_exists_v1\(' and prosrc !~ 'patient\.patients\M'
   from pg_proc where oid = 'appointment.enforce_appointment_transition()'::regprocedure),
  'R3: enforce_appointment_transition calls patient.patient_exists_v1');

select tests.authenticate_as('admin@alpha.example');
select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000004', 'synthetic R3');
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
  values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
          'aa000000-0000-4000-8000-000000000004', '2030-01-07 11:00+05:30', '2030-01-07 11:20+05:30')$$,
  'P0002', 'R3: booking for a soft-deleted patient -> P0002');
select tests.ok(
  tests.affected_rows($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
            'aa000000-0000-4000-8000-000000000002', '2030-01-07 11:00+05:30', '2030-01-07 11:20+05:30')$$) = 1,
  'R3: booking for a live patient still works');
select tests.as_superuser();
set local role service_role;
select tests.throws_ok($$update appointment.appointments set patient_id = 'aa000000-0000-4000-8000-000000000004'
  where id = 'e1111111-0000-4000-8000-000000000001'$$,
  'P0002', 'R3: moving a booking to a soft-deleted patient -> P0002 (also for trusted writers)');
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok($$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
  values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
          'bb000000-0000-4000-8000-000000000001', '2030-01-07 12:00+05:30', '2030-01-07 12:20+05:30')$$,
  'P0002', 'R3: booking another tenant''s patient -> P0002');

-- ============================================ N5: the published v1 surface (signatures) ==
select tests.as_superuser();
create temporary table t_v1 (fn regprocedure, client_ok boolean) on commit drop;
insert into t_v1 values
  ('identity.branch_time_zone_v1(uuid)', true), ('identity.branch_local_date_v1(uuid,timestamptz)', true),
  -- branch_exists_v1 is client-callable so the legacy host can use it until cutover.
  ('identity.branch_exists_v1(uuid,uuid)', true), ('identity.branch_tenant_id_v1(uuid)', false),
  ('appointment.branch_has_open_activity_v1(uuid,uuid)', false), ('appointment.queue_has_entries_v1(uuid,uuid[],date[])', false),
  ('appointment.patient_has_active_visits_v1(uuid,uuid)', false), ('patient.patient_exists_v1(uuid,uuid)', false),
  ('appointment.future_bookings_count_v1(uuid,uuid[])', false),
  -- microservices contracts (20261013090000): the two client-facing reads + the service-only guard
  ('identity.my_tenant_grant_v1(uuid)', true), ('patient.patient_summary_v1(uuid,uuid[])', true),
  ('appointment.patient_has_open_visits_v1(uuid,uuid)', false),
  -- Level 1 (20261019100000 / 20261019103000): MRN prefix (owner-only, used by the MRN trigger) and
  -- the caller's own tenant default calling code (client-facing, membership-checked)
  ('identity.tenant_mrn_prefix_v1(uuid)', false), ('identity.tenant_default_country_code_v1(uuid)', true),
  -- recent patients (20261020130000): latest booking per patient (client-facing, patients.view-checked)
  ('appointment.patient_last_booked_v1(uuid,integer)', true),
  -- billing reads (20261023120100 / 20261023120200 / 20261025240200): service-only, no client execute
  ('identity.caller_roles_v1(uuid)', false),
  ('appointment.appointment_billing_ref_v1(uuid,uuid)', false),
  ('identity.branch_bill_header_v1(uuid,uuid)', false),
  -- earnings reads (20261025250000 / 20261025250100 / 20261025250200): service-only, names survive soft delete
  ('identity.earnings_branches_v1(uuid)', false),
  ('patient.party_label_v1(uuid,uuid)', false),
  ('appointment.practitioner_label_v1(uuid,uuid)', false),
  ('appointment.practitioner_credential_v1(uuid,uuid)', false),
  ('appointment.appointment_consultation_fee_v1(uuid,uuid)', false),
  -- setup wizard (20261025200000): the caller's own step (client-facing, settings.manage-checked)
  ('identity.setup_state_v1()', true);
grant select on t_v1 to public;
select tests.ok(
  (select count(*) = 24 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where p.proname like '%\_v1' and n.nspname in ('identity', 'patient', 'appointment')
     and p.proname not in ('change_time_zone_v1', 'assert_zone_change_allowed_v1', 'advance_setup_v1')),
  'N5: exactly the 24 published v1 read functions exist (plus the change_time_zone_v1 / assert_zone_change_allowed_v1 / advance_setup_v1 commands)');
select tests.ok(
  (select prosecdef and proconfig @> array['search_path=""'] and has_function_privilege('authenticated', oid, 'execute')
          and not has_function_privilege('anon', oid, 'execute')
   from pg_proc where oid = 'identity.assert_zone_change_allowed_v1(uuid,uuid[],text,text,boolean)'::regprocedure),
  'R5: assert_zone_change_allowed_v1 is definer, callable by clients (it only raises; tenant_admin checked), not anon');
select tests.ok(
  (select bool_and(p.prosecdef) from t_v1 join pg_proc p on p.oid = t_v1.fn),
  'N5: every v1 function is SECURITY DEFINER');
select tests.ok(
  (select bool_and(p.proconfig @> array['search_path=""']) from t_v1 join pg_proc p on p.oid = t_v1.fn),
  'N5: every v1 function pins search_path to empty');
select tests.ok(
  (select bool_and(p.provolatile = 's') from t_v1 join pg_proc p on p.oid = t_v1.fn),
  'N5: every v1 read function is STABLE');
select tests.ok(
  (select bool_and(not has_function_privilege('public', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute'))
   from t_v1 join pg_proc p on p.oid = t_v1.fn),
  'N5: no v1 function is executable by PUBLIC or anon');
select tests.ok(
  (select bool_and(has_function_privilege('service_role', p.oid, 'execute')) from t_v1 join pg_proc p on p.oid = t_v1.fn),
  'N5: service_role may execute every v1 function');
select tests.ok(
  (select bool_and(has_function_privilege('authenticated', p.oid, 'execute') = t_v1.client_ok) from t_v1 join pg_proc p on p.oid = t_v1.fn),
  'R6: authenticated may execute the zone reads, branch_exists_v1, my_tenant_grant_v1, patient_summary_v1 and tenant_default_country_code_v1');
select tests.ok(
  (select pg_get_function_result(oid) = 'TABLE(changed boolean, future_bookings integer, time_zone text)'
          and prosecdef and has_function_privilege('authenticated', oid, 'execute')
          and not has_function_privilege('anon', oid, 'execute')
   from pg_proc where oid = 'identity.change_time_zone_v1(uuid,uuid,text,boolean)'::regprocedure),
  'R5: change_time_zone_v1(tenant, branch, zone, confirm) -> (changed, future_bookings, time_zone), definer, clients yes / anon no');
select tests.ok(
  not has_column_privilege('authenticated', 'identity.tenants', 'time_zone', 'update')
  and not has_column_privilege('authenticated', 'identity.branches', 'timezone_override', 'update')
  and has_column_privilege('authenticated', 'identity.branches', 'timezone_override', 'insert'),
  'R5: clients cannot UPDATE zones directly (INSERT of a new branch override stays allowed)');
select tests.ok(
  has_column_privilege('authenticated', 'identity.branches', 'timezone', 'update')
  and has_column_privilege('authenticated', 'identity.branches', 'timezone', 'insert'),
  'MAJ-1: the legacy branches.timezone grants stay for readers/writers built before this migration');
select tests.ok(
  (select not prosecdef from pg_proc where oid = 'identity.guard_time_zone()'::regprocedure),
  'R5: guard_time_zone is SECURITY INVOKER (it must see the real writer)');

-- ============================== R4: the tenant check keys on the session role, not on sub ==
-- Exercise the function bodies as a client: grant the six service-only functions to authenticated
-- for this transaction only (rolled back), then call them without a sub claim.
grant execute on function identity.branch_exists_v1(uuid, uuid), identity.branch_tenant_id_v1(uuid),
  appointment.branch_has_open_activity_v1(uuid, uuid), appointment.queue_has_entries_v1(uuid, uuid[], date[]),
  appointment.patient_has_active_visits_v1(uuid, uuid), patient.patient_exists_v1(uuid, uuid),
  appointment.future_bookings_count_v1(uuid, uuid[]) to authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
set local role authenticated;
select tests.ok(auth.uid() is null, 'R4 setup: authenticated session WITHOUT a sub claim');
select tests.throws_ok($$select patient.patient_exists_v1('22222222-2222-4222-8222-222222222222', 'bb000000-0000-4000-8000-000000000002')$$,
  'P0002', 'R4: no-sub authenticated -> patient_exists_v1 P0002 (was: true, a cross-tenant oracle)');
select tests.throws_ok($$select appointment.patient_has_active_visits_v1('22222222-2222-4222-8222-222222222222', 'bb000000-0000-4000-8000-000000000001')$$,
  'P0002', 'R4: no-sub authenticated -> patient_has_active_visits_v1 P0002');
select tests.throws_ok($$select identity.branch_exists_v1('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'R4: no-sub authenticated -> branch_exists_v1 P0002');
select tests.ok(identity.branch_tenant_id_v1('b2222222-0000-4000-8000-000000000001') is null,
  'R4: no-sub authenticated -> branch_tenant_id_v1 NULL (was: Beta''s tenant id)');
select tests.throws_ok($$select appointment.branch_has_open_activity_v1('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'R4: no-sub authenticated -> branch_has_open_activity_v1 P0002');
select tests.throws_ok($$select appointment.queue_has_entries_v1('22222222-2222-4222-8222-222222222222', array['b2222222-0000-4000-8000-000000000001'::uuid], array[current_date])$$,
  'P0002', 'R4: no-sub authenticated -> queue_has_entries_v1 P0002');
select tests.throws_ok($$select appointment.future_bookings_count_v1('22222222-2222-4222-8222-222222222222', array['b2222222-0000-4000-8000-000000000001'::uuid])$$,
  'P0002', 'R4: no-sub authenticated -> future_bookings_count_v1 P0002');
select tests.throws_ok($$select identity.branch_time_zone_v1('b2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'R4: no-sub authenticated -> branch_time_zone_v1 P0002 (was: Beta''s zone)');
select tests.throws_ok($$select identity.branch_local_date_v1('b2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'R4: no-sub authenticated -> branch_local_date_v1 P0002');
select tests.throws_ok($$select * from identity.change_time_zone_v1('22222222-2222-4222-8222-222222222222', null, 'UTC', true)$$,
  'P0002', 'R4: no-sub authenticated -> change_time_zone_v1 P0002');

-- the same nine with a real JWT of another tenant (cross-tenant -> P0002 / NULL)
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$select patient.patient_exists_v1('22222222-2222-4222-8222-222222222222', 'bb000000-0000-4000-8000-000000000002')$$,
  'P0002', 'cross-tenant JWT -> patient_exists_v1 P0002');
select tests.throws_ok($$select appointment.patient_has_active_visits_v1('22222222-2222-4222-8222-222222222222', 'bb000000-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant JWT -> patient_has_active_visits_v1 P0002');
select tests.throws_ok($$select identity.branch_exists_v1('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant JWT -> branch_exists_v1 P0002');
select tests.ok(identity.branch_tenant_id_v1('b2222222-0000-4000-8000-000000000001') is null,
  'cross-tenant JWT -> branch_tenant_id_v1 NULL');
select tests.throws_ok($$select appointment.branch_has_open_activity_v1('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant JWT -> branch_has_open_activity_v1 P0002');
select tests.throws_ok($$select appointment.queue_has_entries_v1('22222222-2222-4222-8222-222222222222', array['b2222222-0000-4000-8000-000000000001'::uuid], array[current_date])$$,
  'P0002', 'cross-tenant JWT -> queue_has_entries_v1 P0002');
select tests.throws_ok($$select appointment.future_bookings_count_v1('22222222-2222-4222-8222-222222222222', array['b2222222-0000-4000-8000-000000000001'::uuid])$$,
  'P0002', 'cross-tenant JWT -> future_bookings_count_v1 P0002');
select tests.throws_ok($$select identity.branch_time_zone_v1('b2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant JWT -> branch_time_zone_v1 P0002');
select tests.throws_ok($$select identity.branch_local_date_v1('b2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'cross-tenant JWT -> branch_local_date_v1 P0002');
select tests.ok(appointment.future_bookings_count_v1('11111111-1111-4111-8111-111111111111', array['a1111111-0000-4000-8000-000000000001'::uuid]) = 2,
  'own tenant: future_bookings_count_v1 counts the seeded 2030 booking plus the one booked above');

-- trusted path (service_role, no client role) still works
select tests.as_superuser();
set local role service_role;
select tests.ok(patient.patient_exists_v1('22222222-2222-4222-8222-222222222222', 'bb000000-0000-4000-8000-000000000002'),
  'R4: service_role (trusted, no client role) still uses patient_exists_v1');
select tests.ok(identity.branch_time_zone_v1('b2222222-0000-4000-8000-000000000001') = 'Asia/Kolkata',
  'R4: service_role still resolves any branch zone');
select tests.ok(appointment.future_bookings_count_v1('22222222-2222-4222-8222-222222222222', array['b2222222-0000-4000-8000-000000000001'::uuid]) = 1,
  'service_role counts future bookings');

-- ============== R5: non-owner writers cannot bypass the confirmation by updating directly ==
select tests.throws_ok($$update identity.tenants set time_zone = 'Asia/Dubai' where id = '22222222-2222-4222-8222-222222222222'$$,
  '55000', 'R5: service_role changing a zone with future bookings directly -> 55000 time_zone_has_future_bookings');
select tests.throws_ok($$update identity.branches set timezone = 'Asia/Dubai' where id = 'b2222222-0000-4000-8000-000000000001'$$,
  '55000', 'R5: same for a branch override');
select tests.ok(
  tests.affected_rows($$update identity.branches set timezone = 'Asia/Dubai' where id = 'a1111111-0000-4000-8000-000000000002'$$) = 1,
  'R5: a branch without future bookings changes directly (service_role)');
update identity.branches set timezone = 'Asia/Calcutta' where id = 'a1111111-0000-4000-8000-000000000002';
select tests.ok((select timezone = 'Asia/Kolkata' and timezone_override is null from identity.branches where id = 'a1111111-0000-4000-8000-000000000002'),
  'N4/MAJ-1: a legacy write of the tenant zone (as the alias Asia/Calcutta) is canonical and means inherit');
update identity.branches set timezone_override = 'Asia/Calcutta' where id = 'a1111111-0000-4000-8000-000000000002';
select tests.ok((select timezone_override = 'Asia/Kolkata' and timezone = 'Asia/Kolkata' from identity.branches where id = 'a1111111-0000-4000-8000-000000000002'),
  'N4: an alias written to timezone_override is stored canonically');
update identity.branches set timezone_override = null where id = 'a1111111-0000-4000-8000-000000000002';
reset role;
select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  (select not changed and future_bookings = 2 and time_zone is null
   from identity.change_time_zone_v1('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'Asia/Dubai')),
  'R5: a branch override with future bookings needs confirmation (count 2)');
select tests.ok(
  (select changed and future_bookings = 0
   from identity.change_time_zone_v1('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', null)),
  'R5: inheriting again (p_time_zone NULL) at a branch without bookings needs no confirmation');
select tests.as_superuser();
select tests.ok((select timezone_override is null and timezone = 'Asia/Kolkata' from identity.branches where id = 'a1111111-0000-4000-8000-000000000002'),
  'R5: the branch inherits again');

-- ======================================================== N4: stored zones are canonical ==
select tests.ok(
  (select bool_and(timezone = identity.canonical_time_zone(timezone)
                   and timezone_override is not distinct from identity.canonical_time_zone(timezone_override)) from identity.branches)
  and (select bool_and(time_zone = identity.canonical_time_zone(time_zone)) from identity.tenants),
  'N4: every stored zone is canonical');

rollback;
