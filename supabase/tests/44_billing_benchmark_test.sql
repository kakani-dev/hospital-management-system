-- GST Rule 46, cancel/no-show refunds, and maker-checker above a tenant threshold.
begin;

select tests.ok(
  (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'billing' and c.relname = 'approval_settings'),
  'RLS is enabled on billing.approval_settings');

select tests.ok(
  not has_table_privilege('anon', 'billing.approval_settings', 'select')
  and not has_table_privilege('authenticated', 'billing.approval_settings', 'select')
  and has_table_privilege('hms_svc_billing', 'billing.approval_settings', 'select'),
  'only the billing service role can read approval settings');

select tests.ok(
  (select prosecdef and proconfig @> array['search_path=""']
     and has_function_privilege('hms_svc_billing', oid, 'execute')
     and has_function_privilege('service_role', oid, 'execute')
     and not has_function_privilege('anon', oid, 'execute')
     and not has_function_privilege('authenticated', oid, 'execute')
   from pg_proc where oid = 'identity.branch_bill_header_v1(uuid,uuid)'::regprocedure),
  'branch_bill_header_v1 is security definer, search_path empty, and not a client call');

select tests.ok(
  (select prosecdef and proconfig @> array['search_path=""']
     and has_function_privilege('hms_svc_scheduling', oid, 'execute')
     and not has_function_privilege('anon', oid, 'execute')
     and not has_function_privilege('authenticated', oid, 'execute')
   from pg_proc where oid = 'appointment.apply_billing_on_status()'::regprocedure),
  'the appointment billing trigger is security definer with an empty search_path');

-- --------------------------------------------------------------------- GST ----
do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_beta uuid := '22222222-2222-4222-8222-222222222222';
  v_doc jsonb;
  v_bill uuid;
  v_tax uuid;
  v_item uuid;
  v_list uuid;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  perform billing.ensure_defaults(v_tenant);
  v_doc := billing.set_branch_profile(v_tenant, v_branch, jsonb_build_object('gstin', '36aabcu9603r1zm', 'legalName', 'Alpha Hospital'));
  perform tests.ok(v_doc ->> 'gstin' = '36AABCU9603R1ZM' and v_doc ->> 'legalName' = 'Alpha Hospital',
    'a branch GSTIN is stored in uppercase on the billing profile');
  begin
    perform billing.set_branch_profile(v_tenant, v_branch, jsonb_build_object('gstin', 'NOT-A-GSTIN'));
    perform tests.ok(false, 'a bad GSTIN must be refused');
  exception when sqlstate '22023' then
    perform tests.ok(true, 'a GSTIN that is not 15 characters is refused');
  end;
  perform tests.ok((billing.branch_profile_json(v_tenant, v_branch) ->> 'gstin') = '36AABCU9603R1ZM',
    'a rejected GSTIN does not wipe the one already saved');

  execute 'reset role';
  insert into billing.tax_code (tenant_id, code, sac_hsn_code, is_exempt, rate_bp, effective_from)
  values (v_tenant, 'T18', '998311', false, 1800, date '2017-07-01')
  returning id into v_tax;
  insert into billing.service_item (tenant_id, code, name, category, tax_code_id)
  values (v_tenant, 'PROC18', 'Taxable procedure', 'procedure', v_tax)
  returning id into v_item;
  select id into v_list from billing.price_list
  where tenant_id = v_tenant and branch_id is null and name = 'Standard' and not is_deleted;
  insert into billing.price_list_item (tenant_id, price_list_id, service_item_id, unit_price_paise, effective_from)
  values (v_tenant, v_list, v_item, 10000, date '2017-07-01');
  execute 'set local role hms_svc_billing';

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('serviceItemId', v_item));
  v_doc := billing.set_place_of_supply(v_tenant, v_bill, '27');
  perform tests.ok((v_doc -> 'lines' -> 0 ->> 'igstPaise')::bigint = 1800
    and (v_doc -> 'lines' -> 0 ->> 'cgstPaise')::bigint = 0
    and (v_doc ->> 'igstPaise')::bigint = 1800
    and v_doc -> 'lines' -> 0 ->> 'sacHsnCode' = '998311',
    'a different place of supply puts the 18% tax on IGST');
  v_doc := billing.set_place_of_supply(v_tenant, v_bill, '36');
  perform tests.ok((v_doc -> 'lines' -> 0 ->> 'cgstPaise')::bigint = 900
    and (v_doc -> 'lines' -> 0 ->> 'sgstPaise')::bigint = 900
    and (v_doc -> 'lines' -> 0 ->> 'igstPaise')::bigint = 0,
    'the same state splits the tax into CGST and SGST, odd paise to CGST');
  v_doc := billing.finalize_bill(v_tenant, v_bill);
  perform tests.ok(v_doc -> 'supplier' ->> 'gstin' = '36AABCU9603R1ZM'
    and v_doc -> 'supplier' ->> 'name' = 'Alpha Hospital'
    and v_doc ->> 'placeOfSupplyState' = '36',
    'finalize snapshots the supplier GSTIN and legal name');
  perform billing.set_branch_profile(v_tenant, v_branch, jsonb_build_object('gstin', '29AABCU9603R1ZM'));
  perform tests.ok((billing.bill_json(v_bill) -> 'supplier' ->> 'gstin') = '36AABCU9603R1ZM',
    'a later GSTIN edit does not rewrite the issued bill');

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  perform billing.add_line(v_tenant, (v_doc ->> 'id')::uuid, jsonb_build_object('code', 'CONSULT'));
  v_doc := billing.bill_json((v_doc ->> 'id')::uuid);
  perform tests.ok(v_doc -> 'supplier' ->> 'gstin' = '29AABCU9603R1ZM'
    and (v_doc ->> 'cgstPaise')::bigint = 0 and (v_doc ->> 'igstPaise')::bigint = 0
    and v_doc -> 'lines' -> 0 ->> 'sacHsnCode' = '9993',
    'an exempt consult still shows the GSTIN and a zero tax split');

  perform tests.ok(
    (select count(*) from jsonb_array_elements(billing.list_bills(v_tenant, 'finalized', v_branch, null, null)) b
      where b ->> 'id' = v_bill::text) = 1,
    'the bill list returns the finalized bill for this branch');
  perform tests.ok(
    jsonb_array_length(billing.list_bills(v_tenant, 'draft', v_branch, date '1999-01-01', date '1999-01-02')) = 0,
    'a date filter hides bills from another day');
end
$$;

select set_config('request.jwt.claims', jsonb_build_object(
  'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
set local role hms_svc_billing;
select tests.throws_ok(
  $$select * from identity.branch_bill_header_v1('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'a signed-in caller cannot read another tenant''s bill header');
reset role;

-- --------------------------------------------------------------------- maker-checker ----
do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doc jsonb;
  v_bill uuid;
  v_approval uuid;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  perform billing.set_approval_settings(v_tenant, jsonb_build_object('makerCheckerThresholdPaise', 1000));
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT'));

  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000002', true);
  v_doc := billing.request_discount(v_tenant, v_bill, jsonb_build_object('kind', 'flat_paise', 'value', 500, 'reasonCode', 'courtesy'));
  perform tests.ok(v_doc ->> 'approvalStatus' = 'approved'
    and (select approver_id = requested_by from billing.approval_request where id = (v_doc ->> 'approvalId')::uuid),
    'a discount at or under the threshold is approved by the requester when their role allows it');

  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  v_doc := billing.request_discount(v_tenant, v_bill, jsonb_build_object('kind', 'flat_paise', 'value', 5000, 'reasonCode', 'staff'));
  perform tests.ok(v_doc ->> 'status' = 'pending' and (v_doc ->> 'amountPaise')::bigint = 5000, 'a discount above the threshold stays pending even for an admin');
  v_approval := (v_doc ->> 'approvalId')::uuid;
  begin
    perform billing.decide_approval(v_tenant, v_approval, jsonb_build_object('status', 'approved'));
    perform tests.ok(false, 'the requester must not approve their own discount');
  exception when sqlstate '42501' then
    perform tests.ok(true, 'the requester is told someone else must approve it');
  end;
  execute 'reset role';
  update billing.approval_request set requested_by = '0a000000-0000-4000-8000-000000000002' where id = v_approval;
  execute 'set local role hms_svc_billing';
  v_doc := billing.decide_approval(v_tenant, v_approval, jsonb_build_object('status', 'approved'));
  perform tests.ok((v_doc ->> 'discountPaise')::bigint >= 5000, 'a different person can approve the same discount');
end
$$;

-- --------------------------------------------------------------------- cancel / no-show ----
do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doctor uuid := 'c1111111-0000-4000-8000-000000000002';
  v_paid uuid := gen_random_uuid();
  v_unpaid uuid := gen_random_uuid();
  v_noshow uuid := gen_random_uuid();
  v_doc jsonb;
  v_bill uuid;
  v_pay uuid;
  v_approval uuid;
  v_refund uuid;
begin
  execute 'reset role';
  insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason)
  values
    (v_paid, v_tenant, v_branch, v_doctor, v_patient, '2030-01-14 10:00+05:30', '2030-01-14 10:20+05:30', 'Synthetic paid'),
    (v_unpaid, v_tenant, v_branch, v_doctor, v_patient, '2030-01-14 11:00+05:30', '2030-01-14 11:20+05:30', 'Synthetic unpaid'),
    (v_noshow, v_tenant, v_branch, v_doctor, v_patient, '2030-01-14 12:00+05:30', '2030-01-14 12:20+05:30', 'Synthetic no-show');

  perform set_config('appointment.check_in', v_paid::text, true);
  update appointment.appointments set status = 'checked_in' where id = v_paid;
  perform set_config('appointment.check_in', v_unpaid::text, true);
  update appointment.appointments set status = 'checked_in' where id = v_unpaid;
  perform set_config('appointment.check_in', v_noshow::text, true);
  update appointment.appointments set status = 'checked_in' where id = v_noshow;
  perform set_config('appointment.check_in', '', true);

  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  v_doc := billing.ensure_draft(v_tenant, v_paid);
  v_bill := (v_doc ->> 'id')::uuid;
  perform tests.ok(v_doc ->> 'status' = 'draft' and v_doc -> 'lines' -> 0 ->> 'code' = 'CONSULT',
    'checking in opens a consult draft');
  v_doc := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_doc ->> 'accountId', 'kind', 'payment',
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 50000)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', 50000))));
  v_pay := (v_doc ->> 'id')::uuid;

  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000002', true);
  execute 'reset role';
  update appointment.appointments set status = 'cancelled' where id = v_paid;
  execute 'set local role hms_svc_billing';
  select id into v_approval from billing.approval_request
  where action = 'refund' and subject_id = v_pay and status = 'pending' and payload ->> 'appointmentId' = v_paid::text;
  perform tests.ok(v_approval is not null
    and (select amount_paise from billing.approval_request where id = v_approval) = 50000,
    'cancelling a paid visit asks for a full refund and leaves it pending');

  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  v_doc := billing.decide_approval(v_tenant, v_approval, jsonb_build_object('status', 'approved'));
  perform tests.ok(v_doc ->> 'creditNoteNo' is not null and (v_doc ->> 'creditNoteId') is not null,
    'approving the refund issues a credit note on the refund receipt');
  select id into v_refund from billing.payment where refund_of_payment_id = v_pay and not is_deleted;
  perform tests.ok((select due_paise from billing.bill_balance_v1 where bill_id = v_bill) = 0
    and (select credit_note_id from billing.payment where id = v_refund) is not null,
    'the original bill is fully credited and the refund points at the credit note');

  execute 'reset role';
  update appointment.appointments set status = 'cancelled' where id = v_unpaid;
  perform tests.ok((select b.status from billing.bill b
      join billing.billing_account a on a.id = b.account_id
      where a.source_ref_id = v_unpaid and b.bill_kind = 'final') = 'cancelled_draft',
    'cancelling an unpaid draft cancels the draft');
  perform tests.ok(not exists (
      select 1 from billing.approval_request r where r.payload ->> 'appointmentId' = v_unpaid::text),
    'an unpaid cancel does not ask for a refund');

  perform set_config('appointment.eod_close', 'on', true);
  update appointment.appointments set status = 'no_show' where id = v_noshow;
  perform set_config('appointment.eod_close', '', true);
  perform tests.ok(not exists (
      select 1 from billing.approval_request r where r.payload ->> 'appointmentId' = v_noshow::text),
    'the default no-show policy refunds nothing');
end
$$;

do $$
declare
  v_n bigint;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0b000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0b000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  select count(*) into v_n from billing.approval_settings
  where tenant_id = '11111111-1111-4111-8111-111111111111';
  perform tests.ok(v_n = 0, 'another tenant cannot read these approval settings');
end
$$;

rollback;
