-- #165 consult line takes the visit's doctor and fee on the server; #169 walk-in tokens open a consult draft.
-- Migration 20261027160000.
begin;

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doctor uuid := 'c1111111-0000-4000-8000-000000000002';
  v_walk uuid;
  v_doc jsonb;
  v_again jsonb;
  v_bill uuid;
  v_prac uuid;
  v_n int;
begin
  execute 'reset role';
  update appointment.queue_entries set status = 'done'
  where tenant_id = v_tenant and branch_id = v_branch and patient_id = v_patient and status in ('waiting', 'in_consultation');
  select q.queue_entry_id into v_walk from appointment.issue_queue_token(v_tenant, v_branch, v_patient, null, v_doctor) q;

  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';

  -- #169
  v_doc := billing.ensure_walk_in_draft(v_tenant, v_walk);
  v_bill := (v_doc ->> 'id')::uuid;
  perform tests.ok(v_doc ->> 'status' = 'draft' and v_doc -> 'lines' -> 0 ->> 'code' = 'CONSULT'
    and jsonb_array_length(v_doc -> 'lines') = 1,
    'a walk-in token opens a draft with one consultation line');
  select practitioner_id into v_prac from billing.bill_line where bill_id = v_bill and not is_deleted;
  perform tests.ok(v_prac = v_doctor, 'the walk-in consult line carries the token''s doctor');
  v_again := billing.ensure_walk_in_draft(v_tenant, v_walk);
  perform tests.ok((v_again ->> 'id')::uuid = v_bill and jsonb_array_length(v_again -> 'lines') = 1,
    'a second call returns the same bill and adds nothing');
  v_again := billing.consume_event(gen_random_uuid(), 'queue.token_issued',
    jsonb_build_object('tenant_id', v_tenant, 'queue_entry_id', v_walk));
  perform tests.ok((v_again ->> 'id')::uuid = v_bill, 'the queue.token_issued event reuses the walk-in bill');
  begin
    perform billing.ensure_walk_in_draft(v_tenant, gen_random_uuid());
    perform tests.ok(false, 'an unknown queue entry is rejected');
  exception when no_data_found then
    perform tests.ok(true, 'an unknown queue entry is rejected');
  end;
  begin
    perform billing.ensure_walk_in_draft('22222222-2222-4222-8222-222222222222', v_walk);
    perform tests.ok(false, 'another tenant cannot bill this token');
  exception when others then
    perform tests.ok(true, 'another tenant cannot bill this token');
  end;

  -- #165: a manually opened bill with a CONSULT and no practitionerId takes today's doctor.
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_doc := billing.add_line(v_tenant, (v_doc ->> 'id')::uuid, jsonb_build_object('code', 'CONSULT'));
  select practitioner_id into v_prac from billing.bill_line where bill_id = (v_doc ->> 'id')::uuid and not is_deleted;
  perform tests.ok(v_prac = v_doctor, 'a CONSULT added without a doctor takes the doctor of today''s visit');
  v_doc := billing.add_line(v_tenant, (v_doc ->> 'id')::uuid, jsonb_build_object('code', 'CONSULT', 'practitionerId', null));
  select count(*) into v_n from billing.bill_line where bill_id = (v_doc ->> 'id')::uuid and practitioner_id = v_doctor and not is_deleted;
  perform tests.ok(v_n = 2, 'an explicit null practitionerId is resolved the same way');
end
$$;

rollback;
