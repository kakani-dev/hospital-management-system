-- #144: a credit note on an uncredited line works, and each bad line gets its own clear 22023.
-- Synthetic data only.
begin;

create function pg_temp.cn_error(p_tenant uuid, p_bill uuid, p_lines jsonb)
returns text language plpgsql as $f$
begin
  perform billing.create_credit_note(p_tenant, p_bill, jsonb_build_object('lines', p_lines));
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
  v_bill uuid;
  v_other uuid;
  v_line uuid;
  v_other_line uuid;
  v_note jsonb;
  v_err text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  perform billing.ensure_defaults(v_tenant);

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT', 'quantity', 3));
  perform billing.finalize_bill(v_tenant, v_bill);
  select id into v_line from billing.bill_line where bill_id = v_bill and not is_deleted;

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_other := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_other, jsonb_build_object('code', 'CONSULT'));
  perform billing.finalize_bill(v_tenant, v_other);
  select id into v_other_line from billing.bill_line where bill_id = v_other and not is_deleted;

  v_err := pg_temp.cn_error(v_tenant, v_bill, '[{"quantity": 1}]');
  perform tests.ok(v_err = '22023: each credit note line needs a lineId (the bill line to credit)',
    'a line with no lineId says so: ' || v_err);
  v_err := pg_temp.cn_error(v_tenant, v_bill, '[{"lineId": "not-a-uuid", "quantity": 1}]');
  perform tests.ok(v_err = '22023: lineId must be the id of a line on this bill',
    'a malformed lineId is a 22023, not a cast error: ' || v_err);
  v_err := pg_temp.cn_error(v_tenant, v_bill, jsonb_build_array(jsonb_build_object('lineId', v_other_line, 'quantity', 1)));
  perform tests.ok(v_err = '22023: credit note line not found on this bill',
    'a line from another bill is not found on this bill: ' || v_err);
  v_err := pg_temp.cn_error(v_tenant, v_bill, jsonb_build_array(jsonb_build_object('lineId', v_line, 'quantity', 'abc')));
  perform tests.ok(v_err = '22023: credit quantity must be a number', 'a non-numeric quantity: ' || v_err);
  v_err := pg_temp.cn_error(v_tenant, v_bill, jsonb_build_array(jsonb_build_object('lineId', v_line, 'quantity', 0)));
  perform tests.ok(v_err = '22023: credit quantity must be more than zero', 'a zero quantity: ' || v_err);
  v_err := pg_temp.cn_error(v_tenant, v_bill, jsonb_build_array(jsonb_build_object('lineId', v_line, 'quantity', -1)));
  perform tests.ok(v_err = '22023: credit quantity must be more than zero', 'a negative quantity: ' || v_err);
  v_err := pg_temp.cn_error(v_tenant, v_bill, jsonb_build_array(jsonb_build_object('lineId', v_line, 'quantity', 4)));
  perform tests.ok(v_err = '22023: credit quantity exceeds the amount not already credited',
    'more than the line quantity keeps the CRN-002 message: ' || v_err);
  v_err := pg_temp.cn_error(v_tenant, v_bill, jsonb_build_array(
    jsonb_build_object('lineId', v_line, 'quantity', 2), jsonb_build_object('lineId', v_line, 'quantity', 2)));
  perform tests.ok(v_err = '22023: credit quantity exceeds the amount not already credited',
    'the same line twice in one note cannot over-credit: ' || v_err);
  v_err := pg_temp.cn_error(v_tenant, v_bill, '[]');
  perform tests.ok(v_err = '22023: a credit note needs a line', 'no lines: ' || v_err);
  v_err := pg_temp.cn_error(v_tenant, v_bill, '["x"]');
  perform tests.ok(v_err = '22023: each credit note line must be an object {lineId, quantity}', 'a non-object line: ' || v_err);

  -- the #144 report: an uncredited line is credited (the bill line DTO key billLineId works too)
  v_note := billing.create_credit_note(v_tenant, v_bill, jsonb_build_object(
    'lines', jsonb_build_array(jsonb_build_object('billLineId', v_line, 'quantity', 1))));
  perform tests.ok(v_note ->> 'status' = 'finalized' and (v_note -> 'lines' -> 0 ->> 'quantity')::numeric = -1,
    'an uncredited line is credited, with billLineId as an alias for lineId');
  v_note := billing.create_credit_note(v_tenant, v_bill, jsonb_build_object(
    'lines', jsonb_build_array(jsonb_build_object('lineId', v_line, 'quantity', '1'))));
  perform tests.ok((v_note -> 'lines' -> 0 ->> 'quantity')::numeric = -1, 'a numeric string quantity is accepted');
  v_err := pg_temp.cn_error(v_tenant, v_bill, jsonb_build_array(jsonb_build_object('lineId', v_line, 'quantity', 2)));
  perform tests.ok(v_err = '22023: credit quantity exceeds the amount not already credited',
    'only what is left (1) can still be credited: ' || v_err);
  v_note := billing.create_credit_note(v_tenant, v_bill, jsonb_build_object(
    'lines', jsonb_build_array(jsonb_build_object('lineId', v_line))));
  perform tests.ok((v_note -> 'lines' -> 0 ->> 'quantity')::numeric = -1, 'no quantity credits everything left');
  v_err := pg_temp.cn_error(v_tenant, v_bill, jsonb_build_array(jsonb_build_object('lineId', v_line, 'quantity', 1)));
  perform tests.ok(v_err = '22023: this line is already fully credited', 'a fully credited line says so: ' || v_err);
end
$$;

rollback;
