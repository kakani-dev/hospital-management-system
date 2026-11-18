-- #317: default listed slot length uses configured new_consult duration, not a hard-coded value.
begin;

select tests.authenticate_as('admin@alpha.example');

select tests.ok(
  has_function_privilege('authenticated', 'appointment.effective_consult_duration_minutes(uuid, uuid)', 'execute')
  and has_function_privilege('hms_svc_scheduling', 'appointment.effective_consult_duration_minutes(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'appointment.effective_consult_duration_minutes(uuid, uuid)', 'execute'),
  'consult duration is executable by operators and the scheduling service, not anonymously');

select tests.ok(
  appointment.effective_consult_duration_minutes('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001')
    = (select vt.duration_minutes from appointment.visit_types vt
        where vt.tenant_id = '11111111-1111-4111-8111-111111111111' and vt.code = 'new_consult' and not vt.is_deleted),
  'the helper returns the tenant new_consult duration, not a hard-coded number');

update appointment.visit_types
   set duration_minutes = 45
 where tenant_id = '11111111-1111-4111-8111-111111111111' and code = 'new_consult' and not is_deleted;

select tests.ok(
  appointment.effective_consult_duration_minutes('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001') = 45,
  'changing the configured consult duration is reflected');

insert into appointment.visit_type_overrides (tenant_id, visit_type_id, branch_id, duration_minutes)
select '11111111-1111-4111-8111-111111111111', vt.id, 'a1111111-0000-4000-8000-000000000001', 20
  from appointment.visit_types vt
 where vt.tenant_id = '11111111-1111-4111-8111-111111111111' and vt.code = 'new_consult' and not vt.is_deleted;

select tests.ok(
  appointment.effective_consult_duration_minutes('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001') = 20
  and appointment.effective_consult_duration_minutes('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002') = 45,
  'a branch override wins on that branch only');

select tests.authenticate_as('admin@beta.example');
select tests.ok(
  appointment.effective_consult_duration_minutes('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001')
    is distinct from 20,
  'Beta is not affected by an Alpha branch override');

rollback;
