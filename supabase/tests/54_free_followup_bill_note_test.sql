-- Free follow-ups: limit column, entitlement link and bill note. Migration 20261027140000.
begin;

select tests.as_superuser();
select appointment.ensure_default_visit_types('11111111-1111-4111-8111-111111111111');
select tests.ok(
  (select bool_and(follow_up_free_limit = 1) from appointment.visit_types
   where tenant_id = '11111111-1111-4111-8111-111111111111' and not is_deleted),
  'visit types default to one free follow-up per episode');
select tests.throws_ok(
  $$update appointment.visit_types set follow_up_free_limit = 51
    where tenant_id = '11111111-1111-4111-8111-111111111111' and code = 'new_consult'$$,
  '23514', 'a free follow-up limit above 50 is rejected');

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doctor uuid := 'c1111111-0000-4000-8000-000000000002';
  v_prior uuid := gen_random_uuid();
  v_free uuid := gen_random_uuid();
  v_doc jsonb;
  v_item uuid;
  v_list uuid;
begin
  execute 'reset role';
  insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason,
    consultation_fee_paise, granted_follow_up_days, granted_follow_up_fee_paise, granted_follow_up_limit)
  values (v_prior, v_tenant, v_branch, v_doctor, v_patient, '2030-02-01 10:00+05:30', '2030-02-01 10:20+05:30', 'Synthetic first visit',
    50000, 7, 0, 1);
  insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason,
    consultation_fee_paise, follow_up_entitlement_id, consultation_fee_note)
  values (v_free, v_tenant, v_branch, v_doctor, v_patient, '2030-02-04 10:00+05:30', '2030-02-04 10:20+05:30', 'Synthetic follow-up',
    0, v_prior, 'Free follow-up (within 7 days of 1 Feb 2030)');

  begin
    insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason, follow_up_entitlement_id)
    values (gen_random_uuid(), v_tenant, v_branch, v_doctor, v_patient, '2030-02-05 10:00+05:30', '2030-02-05 10:20+05:30', 'Synthetic bad link', gen_random_uuid());
    perform tests.ok(false, 'an entitlement must point at an appointment of the same tenant');
  exception when foreign_key_violation then
    perform tests.ok(true, 'an entitlement must point at an appointment of the same tenant');
  end;

  perform tests.ok(
    (select consultation_fee_paise = 0 and consultation_fee_note = 'Free follow-up (within 7 days of 1 Feb 2030)'
     from appointment.appointment_consultation_fee_v2(v_tenant, v_free)),
    'v2 publishes the snapshotted fee and its note');

  perform set_config('appointment.check_in', v_free::text, true);
  update appointment.appointments set status = 'checked_in' where id = v_free;
  perform set_config('appointment.check_in', '', true);

  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  v_doc := billing.ensure_draft(v_tenant, v_free);
  perform tests.ok(
    v_doc -> 'lines' -> 0 ->> 'code' = 'CONSULT'
    and (v_doc -> 'lines' -> 0 ->> 'unitPricePaise')::bigint = 0
    and v_doc -> 'lines' -> 0 ->> 'note' = 'Free follow-up (within 7 days of 1 Feb 2030)',
    'the check-in consult line is free and carries the follow-up note');

  -- Other services are still charged.
  execute 'reset role';
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  select v_tenant, 'LABFU', 'Synthetic lab test', 'procedure', tax_code_id
  from billing.service_item where tenant_id = v_tenant and code = 'CONSULT' and not is_deleted limit 1
  returning id into v_item;
  select id into v_list from billing.price_list
  where tenant_id = v_tenant and branch_id is null and name = 'Standard' and not is_deleted;
  insert into billing.price_list_item (tenant_id, price_list_id, service_item_id, unit_price_paise, effective_from)
  values (v_tenant, v_list, v_item, 30000, date '2017-07-01');
  execute 'set local role hms_svc_billing';
  v_doc := billing.add_line(v_tenant, (v_doc ->> 'id')::uuid, jsonb_build_object('serviceItemId', v_item));
  perform tests.ok(
    (select (l ->> 'unitPricePaise')::bigint = 30000 and l ->> 'note' is null
     from jsonb_array_elements(billing.bill_json((v_doc ->> 'id')::uuid) -> 'lines') l where l ->> 'code' = 'LABFU'),
    'a lab test on the same free follow-up bill is charged at its catalog price');
end
$$;

rollback;
