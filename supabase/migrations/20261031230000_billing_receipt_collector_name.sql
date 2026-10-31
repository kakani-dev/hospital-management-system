-- OP Counter: receipts show the collector's name, not an email or a "Staff xxxx" stub.
-- cross-schema: approved (billing.receipt_json reads the published identity.staff_display_name_v1;
-- name only, never the email, and only for a member of the payment's tenant).
-- receipt_json: same body as 20261027185000 plus collectedByName. No table, RLS or grant change on it.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- cross-schema: approved (published to service_role and hms_svc_billing only)
create or replace function identity.staff_display_name_v1(p_tenant_id uuid, p_user_id uuid)
returns table (display_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if pg_catalog.current_setting('role', true) is distinct from 'anon'
     and (auth.uid() is not null or pg_catalog.current_setting('role', true) = 'authenticated')
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return query
  select nullif(btrim(p.display_name), '')
  from identity.user_profiles p
  where p.id = p_user_id
    and exists (select 1 from identity.memberships m
                where m.user_id = p_user_id and m.tenant_id = p_tenant_id)
    and nullif(btrim(p.display_name), '') is not null;
end;
$$;
comment on function identity.staff_display_name_v1(uuid, uuid) is
  'v1 (published by identity): display name of a staff member of the tenant. Empty when unknown. Never the email.';
revoke all on function identity.staff_display_name_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function identity.staff_display_name_v1(uuid, uuid) to service_role, hms_svc_billing;

create or replace function billing.receipt_json(p_payment_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_pay billing.payment%rowtype;
  v_tenders jsonb;
  v_alloc jsonb;
  v_note text;
  v_name text;
begin
  select * into v_pay from billing.payment where id = p_payment_id and not is_deleted;
  if v_pay.id is null then
    raise exception 'receipt not found' using errcode = 'P0002';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'mode', t.mode, 'amountPaise', t.amount_paise, 'reference', t.reference,
    'paymentAccountId', t.payment_account_id, 'paymentAccountLabel', pa.label,
    'payeeVpa', pa.vpa
  )), '[]'::jsonb) into v_tenders
  from billing.payment_tender t
  left join billing.payment_account pa on pa.id = t.payment_account_id
  where t.payment_id = p_payment_id and not t.is_deleted;
  select coalesce(jsonb_agg(jsonb_build_object(
    'billId', a.bill_id, 'amountPaise', a.amount_paise
  )), '[]'::jsonb) into v_alloc
  from billing.allocation a where a.payment_id = p_payment_id and not a.is_deleted;
  select s.display_name into v_name
  from identity.staff_display_name_v1(v_pay.tenant_id, v_pay.created_by) s;
  select b.bill_no into v_note from billing.bill b where b.id = v_pay.credit_note_id;
  return jsonb_build_object(
    'id', v_pay.id, 'receiptNo', v_pay.receipt_no, 'kind', v_pay.kind,
    'amountPaise', v_pay.amount_paise, 'idempotencyKey', v_pay.idempotency_key,
    'accountId', v_pay.account_id, 'counterSessionId', v_pay.counter_session_id,
    'refundOfPaymentId', v_pay.refund_of_payment_id,
    'creditNoteId', v_pay.credit_note_id, 'creditNoteNo', v_note,
    'approvalId', v_pay.approval_id, 'tenders', v_tenders, 'allocations', v_alloc,
    'receivedAt', v_pay.received_at, 'collectedBy', v_pay.created_by,
    'collectedByName', v_name);
end;
$$;
