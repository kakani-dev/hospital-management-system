-- #154: POST /bills/{id}/discounts accepted the same discount twice, and the bill total dropped twice.
-- The approved spec allows several discounts per bill (ERD bill ||--o{ discount), so this adds a cap
-- rather than a one-per-bill rule:
--   * the same submission (kind, value, reasonCode, billLineId) while an earlier one is approved or
--     pending returns the earlier result ("duplicate": true) and writes nothing;
--   * approved + pending discounts can't exceed the bill subtotal (billing.bill_gross): 22023 -> 400;
--   * decide_approval re-checks the cap before applying an approved discount.
-- The bill row is locked FOR UPDATE so two requests at once are serialised.
-- cross-schema: approved (existing audit.session_actor_id() calls, unchanged from 20261025240200; nothing new added)
-- Billing schema otherwise. Same signatures, owner and grants.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- Subtotal minus approved and pending bill discounts. Pending amounts are the ones recorded on the request.
create or replace function billing.discount_room(p_bill_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select greatest(billing.bill_gross(p_bill_id), 0)
       - billing.discount_total(p_bill_id)
       - coalesce((
           select sum(a.amount_paise) from billing.approval_request a
           join billing.bill b on b.id = a.subject_id and b.tenant_id = a.tenant_id
           where a.action = 'discount' and a.subject_type = 'bill' and a.subject_id = p_bill_id
             and a.status = 'pending' and not a.is_deleted), 0)
$$;

revoke all on function billing.discount_room(uuid) from public, anon, authenticated;
grant execute on function billing.discount_room(uuid) to hms_svc_billing;

create or replace function billing.request_discount(p_tenant_id uuid, p_bill_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_bill billing.bill%rowtype;
  v_kind text := p_body ->> 'kind';
  v_value bigint := (p_body ->> 'value')::bigint;
  v_line uuid := nullif(p_body ->> 'billLineId', '')::uuid;
  v_base bigint;
  v_amount bigint;
  v_percent integer;
  v_approval uuid;
  v_reason text := btrim(p_body ->> 'reasonCode');
  v_prior billing.approval_request%rowtype;
  v_room bigint;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.discount_request');
  select * into v_bill from billing.bill where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_bill.id is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  if v_bill.status <> 'draft' then
    raise exception 'discounts are requested on a draft bill' using errcode = '55000';
  end if;
  if v_reason is null or v_kind not in ('percent_bp', 'flat_paise') or v_value is null or v_value <= 0 then
    raise exception 'kind, value and reasonCode are required' using errcode = '22023';
  end if;
  if v_line is null then
    v_base := billing.bill_gross(p_bill_id);
  else
    select billing.line_net(l.quantity, l.unit_price_paise) + billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp)
    into v_base from billing.bill_line l where l.id = v_line and l.bill_id = p_bill_id and not l.is_deleted;
  end if;
  if v_base is null or v_base <= 0 then
    raise exception 'nothing to discount' using errcode = '22023';
  end if;
  if v_kind = 'flat_paise' then
    v_amount := v_value;
    v_percent := round(v_value * 10000.0 / v_base)::integer;
  else
    v_percent := v_value::integer;
    v_amount := round(v_base * v_value / 10000.0)::bigint;
  end if;
  if v_amount <= 0 or v_amount > v_base then
    raise exception 'discount is outside the bill' using errcode = '22023';
  end if;
  -- #154: the same submission again (same kind, value, reason and line) while the first is still
  -- active returns the first result. Nothing new is written.
  select * into v_prior from billing.approval_request a
  where a.tenant_id = p_tenant_id and a.action = 'discount' and a.subject_type = 'bill' and a.subject_id = p_bill_id
    and not a.is_deleted and a.status in ('approved', 'pending')
    and a.payload ->> 'kind' = v_kind and (a.payload ->> 'value')::bigint = v_value
    and a.payload ->> 'reasonCode' = v_reason
    and nullif(a.payload ->> 'billLineId', '') is not distinct from v_line::text
  order by a.created_on
  limit 1;
  if v_prior.id is not null then
    if v_prior.status = 'approved' then
      return billing.bill_json(p_bill_id) || jsonb_build_object('approvalId', v_prior.id, 'approvalStatus', 'approved', 'duplicate', true);
    end if;
    return jsonb_build_object('approvalId', v_prior.id, 'status', 'pending', 'amountPaise', v_prior.amount_paise,
      'percentBp', v_prior.percent_bp, 'duplicate', true);
  end if;
  -- #154: approved plus pending discounts can't go over the bill subtotal.
  v_room := billing.discount_room(p_bill_id);
  if v_amount > v_room then
    raise exception 'total discounts would exceed the bill: % is left to discount', to_char(greatest(v_room, 0) / 100.0, 'FM"₹"999999999990.00')
      using errcode = '22023';
  end if;
  if billing.within_limit(p_tenant_id, 'discount', v_amount, v_percent)
     and not billing.needs_checker(p_tenant_id, v_amount) then
    insert into billing.approval_request (
      tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, approver_id, status, decided_at, payload)
    values (
      p_tenant_id, 'discount', 'bill', p_bill_id, v_amount, v_percent, audit.session_actor_id(), audit.session_actor_id(), 'approved', pg_catalog.now(),
      jsonb_build_object('billId', p_bill_id, 'billLineId', v_line, 'kind', v_kind, 'value', v_value, 'reasonCode', v_reason))
    returning id into v_approval;
    insert into billing.discount (tenant_id, bill_id, bill_line_id, kind, value, reason_code, approval_id)
    values (p_tenant_id, p_bill_id, v_line, v_kind, v_value, v_reason, v_approval);
    return billing.bill_json(p_bill_id) || jsonb_build_object('approvalId', v_approval, 'approvalStatus', 'approved');
  end if;
  insert into billing.approval_request (
    tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, status, payload)
  values (
    p_tenant_id, 'discount', 'bill', p_bill_id, v_amount, v_percent, audit.session_actor_id(), 'pending',
    jsonb_build_object('billId', p_bill_id, 'billLineId', v_line, 'kind', v_kind, 'value', v_value, 'reasonCode', v_reason))
  returning id into v_approval;
  return jsonb_build_object('approvalId', v_approval, 'status', 'pending', 'amountPaise', v_amount, 'percentBp', v_percent);
end;
$$;

create or replace function billing.decide_approval(p_tenant_id uuid, p_approval_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_req billing.approval_request%rowtype;
  v_status text := p_body ->> 'status';
  v_refund uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.approve');
  select * into v_req from billing.approval_request
  where id = p_approval_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_req.id is null then
    raise exception 'approval not found' using errcode = 'P0002';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'approval is already decided' using errcode = '55000';
  end if;
  if v_status not in ('approved', 'rejected') then
    raise exception 'status must be approved or rejected' using errcode = '22023';
  end if;
  -- Pending means a second person was required. Another role, or a lower threshold, does not let the maker approve it.
  if v_status = 'approved'
     and v_req.requested_by is not distinct from audit.session_actor_id() then
    raise exception 'You requested this, so someone else must approve it.' using errcode = '42501';
  end if;
  if v_status = 'approved' and not billing.within_limit(p_tenant_id, v_req.action, v_req.amount_paise, v_req.percent_bp) then
    raise exception 'outside your approval limit' using errcode = '42501';
  end if;
  -- #154: lines may have changed while this waited. Approving must still keep the bill's total discount
  -- within its subtotal (this request is pending, so the room excludes it; add it back).
  if v_status = 'approved' and v_req.action = 'discount' then
    perform 1 from billing.bill where id = (v_req.payload ->> 'billId')::uuid for update;
    if v_req.amount_paise > billing.discount_room((v_req.payload ->> 'billId')::uuid) + v_req.amount_paise then
      raise exception 'total discounts would exceed the bill: reject this request or remove another discount'
        using errcode = '22023';
    end if;
  end if;
  update billing.approval_request
  set status = v_status, approver_id = audit.session_actor_id(), decided_at = pg_catalog.now(), note = nullif(p_body ->> 'note', '')
  where id = p_approval_id;
  if v_status = 'approved' and v_req.action = 'discount' then
    insert into billing.discount (tenant_id, bill_id, bill_line_id, kind, value, reason_code, approval_id)
    values (
      p_tenant_id, (v_req.payload ->> 'billId')::uuid, nullif(v_req.payload ->> 'billLineId', '')::uuid,
      v_req.payload ->> 'kind', (v_req.payload ->> 'value')::bigint, v_req.payload ->> 'reasonCode', p_approval_id);
    return billing.bill_json((v_req.payload ->> 'billId')::uuid);
  end if;
  if v_status = 'approved' and v_req.action = 'refund' then
    v_refund := billing.insert_refund(
      p_tenant_id, (v_req.payload ->> 'paymentId')::uuid, (v_req.payload ->> 'amountPaise')::bigint,
      v_req.payload ->> 'mode', nullif(v_req.payload ->> 'reference', ''), p_approval_id, gen_random_uuid(),
      nullif(v_req.payload ->> 'counterSessionId', '')::uuid);
    return billing.receipt_json(v_refund);
  end if;
  return jsonb_build_object('approvalId', p_approval_id, 'status', v_status, 'approverId', audit.session_actor_id());
end;
$$;
