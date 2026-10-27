-- #183: printable receipt. receipt_json also returns when the money was received and who collected
-- it (the auth user id in payment.created_by; the web app shows the signed-in collector's email).
-- Same body as 20261025290000 plus two keys; no table, grant or RLS change.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

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
  select b.bill_no into v_note from billing.bill b where b.id = v_pay.credit_note_id;
  return jsonb_build_object(
    'id', v_pay.id, 'receiptNo', v_pay.receipt_no, 'kind', v_pay.kind,
    'amountPaise', v_pay.amount_paise, 'idempotencyKey', v_pay.idempotency_key,
    'accountId', v_pay.account_id, 'counterSessionId', v_pay.counter_session_id,
    'refundOfPaymentId', v_pay.refund_of_payment_id,
    'creditNoteId', v_pay.credit_note_id, 'creditNoteNo', v_note,
    'approvalId', v_pay.approval_id, 'tenders', v_tenders, 'allocations', v_alloc,
    'receivedAt', v_pay.received_at, 'collectedBy', v_pay.created_by);
end;
$$;
