-- #154: the same discount submitted twice is idempotent, and approved + pending discounts can't
-- exceed the bill subtotal (22023 -> 400). Synthetic data only.
begin;

create function pg_temp.discount_error(p_tenant uuid, p_bill uuid, p_body jsonb)
returns text language plpgsql as $f$
begin
  perform billing.request_discount(p_tenant, p_bill, p_body);
  return 'no error';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end
$f$;

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doc jsonb;
  v_again jsonb;
  v_bill uuid;
  v_gross bigint;
  v_err text;
  v_pending uuid;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  perform billing.ensure_defaults(v_tenant);
  perform billing.set_approval_settings(v_tenant, jsonb_build_object('makerCheckerThresholdPaise', 1000));

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT'));
  v_gross := billing.bill_gross(v_bill);
  perform tests.ok(v_gross > 2000, 'the synthetic bill has a subtotal');

  -- the reported case: flat ₹10 twice
  v_doc := billing.request_discount(v_tenant, v_bill, jsonb_build_object('kind', 'flat_paise', 'value', 1000, 'reasonCode', 'Zz-QA courtesy'));
  perform tests.ok(v_doc ->> 'approvalStatus' = 'approved', 'the first discount applies');
  v_again := billing.request_discount(v_tenant, v_bill, jsonb_build_object('kind', 'flat_paise', 'value', 1000, 'reasonCode', 'Zz-QA courtesy'));
  perform tests.ok(v_again ->> 'approvalId' = v_doc ->> 'approvalId' and (v_again ->> 'duplicate')::boolean,
    'the same submission returns the first approval');
  perform tests.ok(billing.discount_total(v_bill) = 1000, 'the repeat does not discount the bill again');
  perform tests.ok((select count(*) from billing.discount where bill_id = v_bill and not is_deleted) = 1,
    'only one discount row is written');

  -- a different discount is still allowed (the spec allows several per bill)
  v_doc := billing.request_discount(v_tenant, v_bill, jsonb_build_object('kind', 'flat_paise', 'value', 500, 'reasonCode', 'Zz-QA senior'));
  perform tests.ok(billing.discount_total(v_bill) = 1500, 'a second, different discount applies');

  -- pending requests count toward the cap, and a repeated pending request is idempotent
  v_doc := billing.request_discount(v_tenant, v_bill, jsonb_build_object('kind', 'flat_paise', 'value', v_gross - 1500, 'reasonCode', 'Zz-QA staff'));
  perform tests.ok(v_doc ->> 'status' = 'pending', 'a large discount waits for an approver');
  v_pending := (v_doc ->> 'approvalId')::uuid;
  v_again := billing.request_discount(v_tenant, v_bill, jsonb_build_object('kind', 'flat_paise', 'value', v_gross - 1500, 'reasonCode', 'Zz-QA staff'));
  perform tests.ok((v_again ->> 'approvalId')::uuid = v_pending and v_again ->> 'status' = 'pending',
    'a repeated pending request returns the same approval');
  perform tests.ok((select count(*) from billing.approval_request where subject_id = v_bill and status = 'pending') = 1,
    'no second pending request is created');

  v_err := pg_temp.discount_error(v_tenant, v_bill, jsonb_build_object('kind', 'flat_paise', 'value', 1, 'reasonCode', 'Zz-QA extra'));
  perform tests.ok(v_err like '22023: total discounts would exceed the bill: ₹0.00 is left to discount',
    'once the subtotal is used up, another discount is a 22023: ' || v_err);
  v_err := pg_temp.discount_error(v_tenant, v_bill, jsonb_build_object('kind', 'percent_bp', 'value', 100, 'reasonCode', 'Zz-QA extra'));
  perform tests.ok(v_err like '22023: total discounts would exceed the bill%', 'percent discounts are capped too: ' || v_err);

  -- a rejected request frees its room
  execute 'reset role';
  update billing.approval_request set requested_by = '0a000000-0000-4000-8000-000000000002' where id = v_pending;
  execute 'set local role hms_svc_billing';
  perform billing.decide_approval(v_tenant, v_pending, jsonb_build_object('status', 'rejected'));
  v_err := pg_temp.discount_error(v_tenant, v_bill, jsonb_build_object('kind', 'flat_paise', 'value', 1, 'reasonCode', 'Zz-QA extra'));
  perform tests.ok(v_err = 'no error', 'after a rejection there is room again: ' || v_err);
end
$$;

-- approving re-checks the cap
do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doc jsonb;
  v_bill uuid;
  v_gross bigint;
  v_pending uuid;
  v_err text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT'));
  v_gross := billing.bill_gross(v_bill);
  v_doc := billing.request_discount(v_tenant, v_bill, jsonb_build_object('kind', 'flat_paise', 'value', v_gross, 'reasonCode', 'Zz-QA staff'));
  v_pending := (v_doc ->> 'approvalId')::uuid;
  -- simulate an approved discount landing while this one waited (bypassing the request check)
  execute 'reset role';
  update billing.approval_request set requested_by = '0a000000-0000-4000-8000-000000000002' where id = v_pending;
  update billing.approval_request set amount_paise = 1 where id = v_pending;
  execute 'set local role hms_svc_billing';
  v_doc := billing.request_discount(v_tenant, v_bill, jsonb_build_object('kind', 'flat_paise', 'value', 1000, 'reasonCode', 'Zz-QA courtesy'));
  execute 'reset role';
  update billing.approval_request set amount_paise = v_gross where id = v_pending;
  execute 'set local role hms_svc_billing';
  begin
    perform billing.decide_approval(v_tenant, v_pending, jsonb_build_object('status', 'approved'));
    v_err := 'no error';
  exception when others then
    v_err := sqlstate || ': ' || sqlerrm;
  end;
  perform tests.ok(v_err like '22023: total discounts would exceed the bill%', 'approval re-checks the cap: ' || v_err);
  perform tests.ok(billing.discount_total(v_bill) = 1000, 'the over-cap approval wrote nothing');
end
$$;

rollback;
