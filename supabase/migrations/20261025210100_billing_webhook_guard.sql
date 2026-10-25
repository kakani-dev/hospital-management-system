-- Payment webhooks (BUG-19 / BUG-30). HMAC and the timestamp window are checked
-- in the billing service before this function runs. anon cannot call it, so the
-- Data API cannot apply a payment without that check. The event id is stored
-- first and a repeat does not collect a second receipt. tenantId in the body is
-- ignored; the tenant is the payment link's tenant.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function billing.apply_webhook(p_provider text, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event text := p_body ->> 'eventId';
  v_order text := p_body ->> 'providerOrderId';
  v_status text := coalesce(p_body ->> 'status', '');
  v_amount bigint := (p_body ->> 'amountPaise')::bigint;
  v_link billing.payment_link%rowtype;
  v_due bigint;
  v_account uuid;
  v_idem uuid;
  v_receipt jsonb;
  v_session uuid;
begin
  if p_provider is null or length(btrim(p_provider)) = 0 or length(p_provider) > 40 then
    raise exception 'provider is required' using errcode = '22023';
  end if;
  if v_event is null or length(v_event) = 0 or length(v_event) > 200 or v_order is null then
    raise exception 'eventId and providerOrderId are required' using errcode = '22023';
  end if;
  -- A provider retry of an event we already stored is a duplicate, even after the
  -- bill due has changed. A new event is stored only after the amount check, so a
  -- mismatch can be retried with the same event id.
  if exists (
    select 1 from billing.provider_webhook_event e
    where e.provider = p_provider and e.event_id = v_event and not e.is_deleted
  ) then
    return jsonb_build_object('duplicate', true, 'applied', false);
  end if;
  select * into v_link
  from billing.payment_link
  where provider_order_id = v_order and not is_deleted;
  if v_link.id is null then
    raise exception 'payment link not found' using errcode = 'P0002';
  end if;

  if v_status is distinct from 'paid' then
    insert into billing.provider_webhook_event (tenant_id, provider, event_id)
    values (v_link.tenant_id, p_provider, v_event)
    on conflict (provider, event_id) do nothing;
    if not found then
      return jsonb_build_object('duplicate', true, 'applied', false);
    end if;
    return jsonb_build_object('duplicate', false, 'applied', false);
  end if;

  select due_paise, account_id into v_due, v_account
  from billing.bill_balance_v1
  where bill_id = v_link.bill_id;
  if v_amount is distinct from v_due or v_due is null or v_due <= 0 then
    raise exception 'webhook amount does not match the amount due' using errcode = '22023';
  end if;

  insert into billing.provider_webhook_event (tenant_id, provider, event_id)
  values (v_link.tenant_id, p_provider, v_event)
  on conflict (provider, event_id) do nothing;
  if not found then
    return jsonb_build_object('duplicate', true, 'applied', false);
  end if;

  v_session := null;
  if v_link.counter_session_id is not null and exists (
    select 1 from billing.counter_session s
    where s.id = v_link.counter_session_id and s.status = 'open' and not s.is_deleted
  ) then
    v_session := v_link.counter_session_id;
  end if;
  v_idem := md5('webhook:' || p_provider || ':' || v_event)::uuid;
  v_receipt := billing.collect_payment(v_link.tenant_id, v_idem, jsonb_build_object(
    'accountId', v_account, 'kind', 'payment', 'counterSessionId', v_session,
    'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', v_amount, 'reference', v_order)),
    'allocations', jsonb_build_array(jsonb_build_object('billId', v_link.bill_id, 'amountPaise', v_amount))));
  update billing.payment_link set status = 'paid' where id = v_link.id;
  return v_receipt || jsonb_build_object('duplicate', false, 'applied', true);
end;
$$;

revoke all on function billing.apply_webhook(text, jsonb) from public, anon, authenticated;
grant execute on function billing.apply_webhook(text, jsonb) to hms_svc_billing, service_role;

comment on function billing.apply_webhook(text, jsonb) is
  'Applies one provider event to the payment link''s tenant. Replay of event id is a no-op. Not granted to anon; the billing API verifies HMAC first.';
