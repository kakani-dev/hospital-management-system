-- #316 / BIL-007: adding a line to a finalized bill is 55000 with the
-- immutable / credit-note message. A cancelled draft keeps the draft-only wording.
begin;

create function pg_temp.add_line_error(p_tenant uuid, p_bill uuid)
returns text language plpgsql as $f$
begin
  perform billing.add_line(p_tenant, p_bill, jsonb_build_object('code', 'CONSULT'));
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
  v_cancelled uuid;
  v_lines int;
  v_err text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  perform billing.ensure_defaults(v_tenant);

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT'));
  perform billing.finalize_bill(v_tenant, v_bill);
  select count(*) into v_lines from billing.bill_line where bill_id = v_bill and not is_deleted;

  v_err := pg_temp.add_line_error(v_tenant, v_bill);
  perform tests.ok(v_err = '55000: finalized bills are immutable; issue a credit note',
    'BIL-007: a finalized bill refuses a new line with the credit-note message: ' || v_err);
  perform tests.ok(
    (select count(*) from billing.bill_line where bill_id = v_bill and not is_deleted) = v_lines
    and (select status from billing.bill where id = v_bill) = 'finalized',
    'the finalized bill and its lines are unchanged');

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_cancelled := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_cancelled, jsonb_build_object('code', 'CONSULT'));
  perform billing.cancel_draft(v_tenant, v_cancelled);
  v_err := pg_temp.add_line_error(v_tenant, v_cancelled);
  perform tests.ok(v_err = '55000: only a draft bill accepts lines',
    'a cancelled draft still uses the draft-only message: ' || v_err);
end
$$;

rollback;
