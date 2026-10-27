-- cross-schema: approved (none; billing schema only).
-- #145: refunds at or below the tenant's maker-checker threshold complete straight away
-- instead of always going to pending approval; cash refunds without an open counter session,
-- or cash refunds of a digital payment by a non-manager, are rejected up front.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.request_refund(p_tenant_id uuid, p_payment_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_src billing.payment%rowtype;
  v_amount bigint := (p_body ->> 'amountPaise')::bigint;
  v_mode text := nullif(p_body ->> 'mode', '');
  v_session uuid := nullif(p_body ->> 'counterSessionId', '')::uuid;
  v_approval uuid;
  v_percent integer;
  v_id uuid;
  v_digital boolean;
  v_payload jsonb;
  v_left bigint;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.refund');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('billing.payment:' || p_payment_id::text, 0));
  select * into v_src from billing.payment where id = p_payment_id and tenant_id = p_tenant_id and not is_deleted;
  if v_src.id is null then
    raise exception 'payment not found' using errcode = 'P0002';
  end if;
  if v_src.kind = 'refund' then
    raise exception 'a refund cannot be refunded' using errcode = '22023';
  end if;
  if v_amount is null then
    v_amount := v_src.amount_paise;
  end if;
  v_left := v_src.amount_paise
    - coalesce((select sum(r.amount_paise) from billing.payment r
                where r.refund_of_payment_id = p_payment_id and not r.is_deleted), 0)
    - coalesce((select sum(ar.amount_paise) from billing.approval_request ar
                where ar.tenant_id = p_tenant_id and ar.action = 'refund' and ar.subject_id = p_payment_id
                  and ar.status = 'pending' and not ar.is_deleted), 0);
  if v_amount is null or v_amount <= 0 or v_amount > v_left then
    raise exception 'refund exceeds the amount still refundable' using errcode = '22023';
  end if;
  v_percent := case when v_src.amount_paise > 0 then round(v_amount * 10000.0 / v_src.amount_paise)::integer else null end;
  if v_mode is null then
    select mode into v_mode from billing.payment_tender where payment_id = p_payment_id and not is_deleted
    order by amount_paise desc limit 1;
  end if;
  v_payload := jsonb_strip_nulls(jsonb_build_object(
    'paymentId', p_payment_id, 'amountPaise', v_amount, 'mode', v_mode,
    'reference', p_body ->> 'reference', 'counterSessionId', v_session,
    'appointmentId', nullif(p_body ->> 'appointmentId', '')));
  v_digital := exists (
    select 1 from billing.payment_tender t where t.payment_id = p_payment_id and not t.is_deleted and t.mode <> 'cash');
  -- #145: check the cash guards up front so a refund that can never be paid out is
  -- rejected now instead of being parked as a pending approval (REF-006 / REF-007).
  if v_mode = 'cash' and v_digital and not billing.caller_is_manager(p_tenant_id) and not billing.bypass_acl() then
    raise exception 'a cash refund of a digital payment needs a manager' using errcode = '42501';
  end if;
  perform billing.refund_session(
    p_tenant_id, (select a.branch_id from billing.billing_account a where a.id = v_src.account_id),
    v_mode, v_src.counter_session_id, v_session);
  -- #145: the tenant's maker-checker threshold decides. At or below it the refund completes
  -- now; above it a different user must approve. The comparison itself (#115) is unchanged
  -- in billing.needs_checker. Role refund limits still apply when someone approves.
  if not billing.needs_checker(p_tenant_id, v_amount) then
    insert into billing.approval_request (
      tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, approver_id, status, decided_at, payload)
    values (
      p_tenant_id, 'refund', 'payment', p_payment_id, v_amount, v_percent,
      audit.session_actor_id(), audit.session_actor_id(), 'approved', pg_catalog.now(), v_payload)
    returning id into v_approval;
    v_id := billing.insert_refund(
      p_tenant_id, p_payment_id, v_amount, v_mode, nullif(p_body ->> 'reference', ''), v_approval, gen_random_uuid(), v_session);
    return billing.receipt_json(v_id);
  end if;
  insert into billing.approval_request (
    tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, status, payload)
  values (
    p_tenant_id, 'refund', 'payment', p_payment_id, v_amount, v_percent, audit.session_actor_id(), 'pending', v_payload)
  returning id into v_approval;
  return jsonb_build_object('approvalId', v_approval, 'status', 'pending');
end;
$$;
