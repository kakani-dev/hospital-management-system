-- Payment webhooks: anon cannot apply them, repeats do not collect twice, the body tenant is ignored.
begin;

select tests.ok(
  not has_function_privilege('anon', 'billing.apply_webhook(text, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'billing.apply_webhook(text, jsonb)', 'execute')
  and not has_function_privilege('public', 'billing.apply_webhook(text, jsonb)', 'execute')
  and has_function_privilege('hms_svc_billing', 'billing.apply_webhook(text, jsonb)', 'execute'),
  'only the billing service role can apply a webhook');

set local role anon;
select tests.throws_ok(
  $$select billing.apply_webhook('stub', '{}'::jsonb)$$,
  '42501', 'anon cannot execute apply_webhook');
reset role;

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_doc jsonb;
  v_bill uuid;
  v_link jsonb;
  v_order text;
  v_event text := 'evt-webhook-41';
  v_hook jsonb;
  v_again jsonb;
  v_other uuid;
  v_failed text := 'evt-webhook-41-failed';
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_bill := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_bill, jsonb_build_object('code', 'CONSULT'));
  v_link := billing.create_payment_link(v_tenant, v_bill, jsonb_build_object('channel', 'qr'));
  v_order := v_link ->> 'providerOrderId';

  begin
    perform billing.apply_webhook('stub', jsonb_build_object(
      'eventId', v_event, 'providerOrderId', v_order, 'status', 'paid', 'amountPaise', 1,
      'tenantId', '22222222-2222-4222-8222-222222222222'));
    perform tests.ok(false, 'a partial amount must be rejected');
  exception when sqlstate '22023' then
    perform tests.ok(true, 'a partial amount is rejected');
  end;
  perform tests.ok(
    not exists (select 1 from billing.provider_webhook_event where provider = 'stub' and event_id = v_event),
    'a rejected amount does not consume the event id');

  v_hook := billing.apply_webhook('stub', jsonb_build_object(
    'eventId', v_event, 'providerOrderId', v_order, 'status', 'paid', 'amountPaise', 50000,
    'tenantId', '22222222-2222-4222-8222-222222222222'));
  perform tests.ok(
    (v_hook ->> 'applied')::boolean and (v_hook ->> 'duplicate')::boolean = false
    and (select tenant_id from billing.provider_webhook_event where provider = 'stub' and event_id = v_event) = v_tenant
    and (billing.bill_json(v_bill) ->> 'duePaise')::bigint = 0,
    'the paid webhook settles the link tenant and ignores tenantId in the body');

  v_again := billing.apply_webhook('stub', jsonb_build_object(
    'eventId', v_event, 'providerOrderId', v_order, 'status', 'paid', 'amountPaise', 50000));
  perform tests.ok(
    (v_again ->> 'duplicate')::boolean and (v_again ->> 'applied')::boolean = false
    and (select count(*) from billing.provider_webhook_event where provider = 'stub' and event_id = v_event) = 1
    and (billing.bill_json(v_bill) ->> 'duePaise')::bigint = 0,
    'the same event id does not collect a second receipt');

  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_other := (v_doc ->> 'id')::uuid;
  perform billing.add_line(v_tenant, v_other, jsonb_build_object('code', 'CONSULT'));
  v_link := billing.create_payment_link(v_tenant, v_other, jsonb_build_object('channel', 'qr'));
  v_hook := billing.apply_webhook('sandbox', jsonb_build_object(
    'eventId', v_failed, 'providerOrderId', v_link ->> 'providerOrderId', 'status', 'failed', 'amountPaise', 50000));
  perform tests.ok(
    (v_hook ->> 'applied')::boolean = false and (v_hook ->> 'duplicate')::boolean = false
    and (billing.bill_json(v_other) ->> 'duePaise')::bigint = 50000,
    'a non-paid event is stored and does not collect');
  v_again := billing.apply_webhook('sandbox', jsonb_build_object(
    'eventId', v_failed, 'providerOrderId', v_link ->> 'providerOrderId', 'status', 'failed', 'amountPaise', 50000));
  perform tests.ok((v_again ->> 'duplicate')::boolean and (billing.bill_json(v_other) ->> 'duePaise')::bigint = 50000,
    'a repeated non-paid event is a duplicate');
end
$$;

rollback;
