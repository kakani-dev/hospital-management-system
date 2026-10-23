-- cross-schema: approved (replaces billing commands that already call identity.*, audit.session_actor_id,
-- and the published appointment/patient functions. No new table reads outside billing.)
-- Billing v1.1. Consultation money is allocated to the open bill. The tax invoice number
-- (CGST Rule 46: gapless, at most 16 characters, per branch and fiscal year) is assigned
-- only when that bill is closed. The receipt number is still assigned when the money is taken.
--
-- This migration alters existing objects:
--   billing.assert_allocation_bound, bill_json, receipt_json, patient_summary, collect_payment,
--   cancel_draft, request_refund, decide_approval, create_payment_link, apply_webhook
--   billing.insert_refund gains a session argument; the previous 7-argument function is dropped
--   UPDATE is revoked on billing.payment, billing.payment_tender and billing.allocation
--   BEFORE UPDATE/DELETE triggers reject changes to those three tables
--   BEFORE UPDATE/DELETE on billing.bill_line rejects a change to a line already covered by allocations
--   AFTER triggers reject a bill total that falls below money already allocated
--   billing.payment_link.counter_session_id is a new nullable column
-- It does not rewrite existing rows. A finalized bill stays finalized. Payment rows are not
-- backfilled (is_deleted stays false; there is no void). From this migration on, a cash tender
-- at a counter needs an open session, and an allocation may target a draft bill.
set local lock_timeout = '5s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

alter table billing.payment_link
  add column if not exists counter_session_id uuid references billing.counter_session (id);

comment on column billing.payment_link.counter_session_id is
  'Session that issued the link, when the cashier had one open. The webhook copies it onto the receipt if that session is still open.';

comment on table billing.payment is
  'Immutable receipt. A correction is a new refund row, never an update and never is_deleted. The receipt number is gapless and assigned when the money is taken.';

comment on table billing.payment_tender is
  'Immutable tender. Cash taken at a counter is stored on a payment whose counter_session_id is the open drawer, so close_session sees the receipt and any cash refund.';

comment on table billing.allocation is
  'Immutable application of a receipt to one bill. A reversal is a new negative row. An open draft and a finalized bill both accept allocations up to the current total.';

create index if not exists counter_session_cashier_open_idx
  on billing.counter_session (tenant_id, cashier_id)
  where status = 'open' and not is_deleted;

-- --------------------------------------------------------------------- money locks ----
create or replace function billing.allocated_paise(p_bill_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(a.amount_paise), 0)::bigint
  from billing.allocation a
  where a.bill_id = p_bill_id and not a.is_deleted
$$;

comment on function billing.allocated_paise(uuid) is
  'Net allocations on one bill, including reversal rows. Not stored.';

-- A line is locked when earlier lines do not already absorb the money taken.
-- Coverage is derived in line_no order. Nothing is copied onto the line.
create or replace function billing.line_is_locked(p_line_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select billing.allocated_paise(l.bill_id) > coalesce((
      select sum(
        billing.line_net(earlier.quantity, earlier.unit_price_paise)
        + billing.line_tax(earlier.quantity, earlier.unit_price_paise, earlier.tax_rate_bp)
      )
      from billing.bill_line earlier
      where earlier.bill_id = l.bill_id
        and not earlier.is_deleted
        and earlier.line_no < l.line_no
    ), 0)
    from billing.bill_line l
    where l.id = p_line_id and not l.is_deleted
  ), false)
$$;

comment on function billing.line_is_locked(uuid) is
  'True when this line is inside the money already allocated, in line_no order. Refunding the receipt unlocks it.';

create or replace function billing.reject_paid_line_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if billing.line_is_locked(old.id) then
      raise exception 'a paid line is locked; refund the receipt or issue a credit note' using errcode = '55000';
    end if;
    return old;
  end if;
  if new.quantity is not distinct from old.quantity
     and new.unit_price_paise is not distinct from old.unit_price_paise
     and new.tax_rate_bp is not distinct from old.tax_rate_bp
     and new.is_deleted is not distinct from old.is_deleted
     and new.bill_id is not distinct from old.bill_id
     and new.service_item_id is not distinct from old.service_item_id
     and new.line_no is not distinct from old.line_no then
    return new;
  end if;
  if billing.line_is_locked(old.id) then
    raise exception 'a paid line is locked; refund the receipt or issue a credit note' using errcode = '55000';
  end if;
  return new;
end;
$$;

create trigger bill_line_paid_lock
  before update or delete on billing.bill_line
  for each row execute function billing.reject_paid_line_change();

create or replace function billing.reject_money_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'payments, tenders and allocations are immutable; refund or reverse them' using errcode = '55000';
end;
$$;

create trigger payment_money_immutable
  before update or delete on billing.payment
  for each row execute function billing.reject_money_change();

create trigger payment_tender_money_immutable
  before update or delete on billing.payment_tender
  for each row execute function billing.reject_money_change();

create trigger allocation_money_immutable
  before update or delete on billing.allocation
  for each row execute function billing.reject_money_change();

revoke update on billing.payment, billing.payment_tender, billing.allocation
  from public, anon, authenticated, hms_svc_billing;

create or replace function billing.assert_bill_still_covered()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bill uuid := coalesce(new.bill_id, old.bill_id);
  v_kind text;
  v_total bigint;
begin
  select b.bill_kind into v_kind from billing.bill b where b.id = v_bill;
  if v_kind is distinct from 'credit_note' then
    select t.total_paise into v_total from billing.bill_totals_v1 t where t.bill_id = v_bill;
    if billing.allocated_paise(v_bill) > coalesce(v_total, 0) then
      raise exception 'the bill total cannot fall below money already allocated' using errcode = '55000';
    end if;
  end if;
  if tg_op = 'UPDATE' and old.bill_id is distinct from new.bill_id then
    select b.bill_kind into v_kind from billing.bill b where b.id = old.bill_id;
    if v_kind is distinct from 'credit_note' then
      select t.total_paise into v_total from billing.bill_totals_v1 t where t.bill_id = old.bill_id;
      if billing.allocated_paise(old.bill_id) > coalesce(v_total, 0) then
        raise exception 'the bill total cannot fall below money already allocated' using errcode = '55000';
      end if;
    end if;
  end if;
  return null;
end;
$$;

revoke all on function billing.assert_bill_still_covered() from public, anon, authenticated;

create constraint trigger bill_line_cover_allocations
  after insert or update or delete on billing.bill_line
  deferrable initially immediate
  for each row execute function billing.assert_bill_still_covered();

create constraint trigger discount_cover_allocations
  after insert or update or delete on billing.discount
  deferrable initially immediate
  for each row execute function billing.assert_bill_still_covered();

-- Allocations settle the current total of a draft or a finalized bill for the same patient.
-- The tax invoice may still be unnumbered. A credit note is not a place to put a receipt.
create or replace function billing.assert_allocation_bound()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment uuid := coalesce(new.payment_id, old.payment_id);
  v_amount bigint;
  v_sum bigint;
  v_pay_patient uuid;
  v_pay_tenant uuid;
  v_status text;
  v_kind text;
  v_bill_patient uuid;
  v_bill_tenant uuid;
  v_bill_sum bigint;
  v_total bigint;
begin
  select p.amount_paise, a.patient_id, p.tenant_id
    into v_amount, v_pay_patient, v_pay_tenant
  from billing.payment p
  join billing.billing_account a on a.id = p.account_id
  where p.id = v_payment;
  select coalesce(sum(al.amount_paise), 0) into v_sum
    from billing.allocation al
    where al.payment_id = v_payment and not al.is_deleted;
  if v_sum > v_amount or v_sum < 0 then
    raise exception 'allocations exceed the payment' using errcode = '23514';
  end if;
  if tg_op <> 'DELETE' then
    select b.status, b.bill_kind, a.patient_id, b.tenant_id
      into v_status, v_kind, v_bill_patient, v_bill_tenant
    from billing.bill b
    join billing.billing_account a on a.id = b.account_id
    where b.id = new.bill_id;
    if v_status not in ('draft', 'finalized')
       or v_kind = 'credit_note'
       or v_bill_patient is distinct from v_pay_patient
       or v_bill_tenant is distinct from v_pay_tenant
       or new.tenant_id is distinct from v_pay_tenant then
      raise exception 'allocations apply to an open or finalized bill for the same patient' using errcode = '55000';
    end if;
    select coalesce(sum(al.amount_paise), 0) into v_bill_sum
      from billing.allocation al
      where al.bill_id = new.bill_id and not al.is_deleted;
    select t.total_paise into v_total from billing.bill_totals_v1 t where t.bill_id = new.bill_id;
    if v_bill_sum > coalesce(v_total, 0) or v_bill_sum < 0 then
      raise exception 'allocations exceed the bill total' using errcode = '23514';
    end if;
  end if;
  return null;
end;
$$;

-- --------------------------------------------------------------------- sessions ----
create or replace function billing.assert_counter_session(
  p_tenant_id uuid, p_session_id uuid, p_branch_id uuid, p_required boolean)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_status text;
  v_cashier uuid;
  v_branch uuid;
begin
  if p_session_id is null then
    if p_required then
      raise exception 'cash taken at a counter needs an open session' using errcode = '55000';
    end if;
    return;
  end if;
  select s.status, s.cashier_id, c.branch_id
    into v_status, v_cashier, v_branch
  from billing.counter_session s
  join billing.counter c on c.id = s.counter_id and not c.is_deleted
  where s.id = p_session_id and s.tenant_id = p_tenant_id and not s.is_deleted;
  if v_status is null then
    raise exception 'counter session not found' using errcode = 'P0002';
  end if;
  if v_status <> 'open' then
    raise exception 'counter session is not open' using errcode = '55000';
  end if;
  if v_branch is distinct from p_branch_id then
    raise exception 'counter session is for another branch' using errcode = '42501';
  end if;
  if not billing.bypass_acl() and v_cashier is distinct from audit.session_actor_id() then
    raise exception 'counter session belongs to another cashier' using errcode = '42501';
  end if;
end;
$$;

comment on function billing.assert_counter_session(uuid, uuid, uuid, boolean) is
  'Cash requires an open session at this branch for this cashier. A named session on a digital tender must still be open.';

-- The cashier's open drawer at this branch, or a new one with a zero float.
-- The counter name is derived from the cashier id so the desk does not type one.
create or replace function billing.ensure_cashier_session(p_tenant_id uuid, p_branch_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cashier uuid := audit.session_actor_id();
  v_name text;
  v_counter uuid;
  v_session uuid;
  v_day date;
  v_opened boolean := false;
  v_holder uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  if v_cashier is null then
    raise exception 'a counter session needs a signed-in cashier' using errcode = '42501';
  end if;
  select s.id, s.business_date into v_session, v_day
  from billing.counter_session s
  join billing.counter c on c.id = s.counter_id and not c.is_deleted
  where s.tenant_id = p_tenant_id
    and s.cashier_id = v_cashier
    and s.status = 'open'
    and not s.is_deleted
    and c.branch_id = p_branch_id
  limit 1;
  if v_session is not null then
    return jsonb_build_object('id', v_session, 'businessDate', v_day, 'opened', false);
  end if;
  v_name := 'C' || replace(v_cashier::text, '-', '');
  insert into billing.counter (tenant_id, branch_id, name)
  values (p_tenant_id, p_branch_id, v_name)
  on conflict (tenant_id, branch_id, name) do nothing;
  select id into v_counter from billing.counter
  where tenant_id = p_tenant_id and branch_id = p_branch_id and name = v_name and not is_deleted;
  if v_counter is null then
    raise exception 'counter not found' using errcode = 'P0002';
  end if;
  v_day := identity.branch_local_date_v1(p_branch_id, pg_catalog.now());
  insert into billing.counter_session (tenant_id, counter_id, cashier_id, business_date, opening_float_paise)
  values (p_tenant_id, v_counter, v_cashier, v_day, 0)
  on conflict (counter_id) where status = 'open' and not is_deleted
  do nothing
  returning id into v_session;
  if v_session is null then
    select id, cashier_id into v_session, v_holder
    from billing.counter_session
    where counter_id = v_counter and status = 'open' and not is_deleted;
    if v_holder is distinct from v_cashier then
      raise exception 'counter session belongs to another cashier' using errcode = '42501';
    end if;
  else
    v_opened := true;
  end if;
  return jsonb_build_object('id', v_session, 'businessDate', v_day, 'opened', v_opened);
end;
$$;

comment on function billing.ensure_cashier_session(uuid, uuid) is
  'Returns the cashier''s open session at this branch, opening one with a zero float when none is open.';

create or replace function billing.find_cashier_session(p_tenant_id uuid, p_branch_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_cashier uuid := audit.session_actor_id();
  v_session uuid;
  v_day date;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  select s.id, s.business_date into v_session, v_day
  from billing.counter_session s
  join billing.counter c on c.id = s.counter_id and not c.is_deleted
  where s.tenant_id = p_tenant_id
    and s.cashier_id = v_cashier
    and s.status = 'open'
    and not s.is_deleted
    and c.branch_id = p_branch_id
  limit 1;
  if v_session is null then
    return jsonb_build_object('id', null);
  end if;
  return jsonb_build_object('id', v_session, 'businessDate', v_day, 'opened', false);
end;
$$;

comment on function billing.find_cashier_session(uuid, uuid) is
  'The cashier''s open session at this branch, or id null. Does not open a drawer.';

-- Prefer the drawer the original cash went into while it is still open.
-- Otherwise the cashier's current drawer. Digital refunds may have no drawer.
create or replace function billing.refund_session(
  p_tenant_id uuid, p_branch_id uuid, p_mode text, p_source_session uuid, p_requested uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_session uuid;
  v_status text;
  v_branch uuid;
begin
  if p_requested is not null then
    perform billing.assert_counter_session(p_tenant_id, p_requested, p_branch_id, true);
    return p_requested;
  end if;
  if p_source_session is not null then
    select s.status, c.branch_id into v_status, v_branch
    from billing.counter_session s
    join billing.counter c on c.id = s.counter_id
    where s.id = p_source_session and s.tenant_id = p_tenant_id and not s.is_deleted;
    if v_status = 'open' and v_branch is not distinct from p_branch_id then
      return p_source_session;
    end if;
  end if;
  select s.id into v_session
  from billing.counter_session s
  join billing.counter c on c.id = s.counter_id and not c.is_deleted
  where s.tenant_id = p_tenant_id
    and s.cashier_id = audit.session_actor_id()
    and s.status = 'open'
    and not s.is_deleted
    and c.branch_id = p_branch_id
  limit 1;
  if v_session is not null then
    return v_session;
  end if;
  if p_mode = 'cash' then
    raise exception 'a cash refund needs an open counter session' using errcode = '55000';
  end if;
  return null;
end;
$$;

comment on function billing.refund_session(uuid, uuid, text, uuid, uuid) is
  'Drawer a refund reduces. Cash with no open drawer is refused. A digital refund may be unattached.';

-- --------------------------------------------------------------------- documents ----
create or replace function billing.bill_json(p_bill_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_bill billing.bill%rowtype;
  v_account billing.billing_account%rowtype;
  v_totals billing.bill_totals_v1%rowtype;
  v_due bigint;
  v_lines jsonb;
  v_discounts jsonb;
begin
  select * into v_bill from billing.bill where id = p_bill_id and not is_deleted;
  if v_bill.id is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  select * into v_account from billing.billing_account where id = v_bill.account_id;
  select * into v_totals from billing.bill_totals_v1 where bill_id = p_bill_id;
  select due_paise into v_due from billing.bill_balance_v1 where bill_id = p_bill_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', l.id, 'lineNo', l.line_no, 'serviceItemId', l.service_item_id,
    'code', si.code, 'name', si.name, 'quantity', l.quantity,
    'unitPricePaise', l.unit_price_paise, 'taxRateBp', l.tax_rate_bp,
    'netPaise', billing.line_net(l.quantity, l.unit_price_paise),
    'taxPaise', billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp),
    'practitionerId', l.practitioner_id,
    'locked', billing.line_is_locked(l.id)
  ) order by l.line_no), '[]'::jsonb) into v_lines
  from billing.bill_line l
  join billing.service_item si on si.id = l.service_item_id
  where l.bill_id = p_bill_id and not l.is_deleted;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'billLineId', d.bill_line_id, 'kind', d.kind, 'value', d.value,
    'reasonCode', d.reason_code, 'approvalId', d.approval_id
  )), '[]'::jsonb) into v_discounts
  from billing.discount d
  join billing.approval_request a on a.id = d.approval_id and a.status = 'approved' and not a.is_deleted
  where d.bill_id = p_bill_id and not d.is_deleted;
  return jsonb_build_object(
    'id', v_bill.id, 'billNo', v_bill.bill_no, 'status', v_bill.status, 'billKind', v_bill.bill_kind,
    'payerType', v_bill.payer_type, 'accountId', v_bill.account_id, 'patientId', v_account.patient_id,
    'branchId', v_account.branch_id, 'reversesBillId', v_bill.reverses_bill_id,
    'lines', v_lines, 'discounts', v_discounts,
    'netPaise', v_totals.net_paise, 'taxPaise', v_totals.tax_paise,
    'discountPaise', v_totals.discount_paise, 'exactPaise', v_totals.exact_paise,
    'roundOffPaise', v_totals.round_off_paise, 'totalPaise', v_totals.total_paise,
    'allocatedPaise', billing.allocated_paise(p_bill_id),
    'duePaise', coalesce(v_due, v_totals.total_paise));
end;
$$;

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
begin
  select * into v_pay from billing.payment where id = p_payment_id and not is_deleted;
  if v_pay.id is null then
    raise exception 'receipt not found' using errcode = 'P0002';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'mode', t.mode, 'amountPaise', t.amount_paise, 'reference', t.reference
  )), '[]'::jsonb) into v_tenders
  from billing.payment_tender t where t.payment_id = p_payment_id and not t.is_deleted;
  select coalesce(jsonb_agg(jsonb_build_object(
    'billId', a.bill_id, 'amountPaise', a.amount_paise
  )), '[]'::jsonb) into v_alloc
  from billing.allocation a where a.payment_id = p_payment_id and not a.is_deleted;
  return jsonb_build_object(
    'id', v_pay.id, 'receiptNo', v_pay.receipt_no, 'kind', v_pay.kind,
    'amountPaise', v_pay.amount_paise, 'idempotencyKey', v_pay.idempotency_key,
    'accountId', v_pay.account_id, 'counterSessionId', v_pay.counter_session_id,
    'refundOfPaymentId', v_pay.refund_of_payment_id,
    'approvalId', v_pay.approval_id, 'tenders', v_tenders, 'allocations', v_alloc);
end;
$$;

create or replace function billing.patient_summary(p_tenant_id uuid, p_patient_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_advance bigint;
  v_accounts jsonb;
  v_bills jsonb;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  perform billing.assert_patient(p_tenant_id, p_patient_id);
  select advance_paise into v_advance from billing.patient_advance_v1
  where tenant_id = p_tenant_id and patient_id = p_patient_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'branchId', a.branch_id, 'accountType', a.account_type,
    'status', a.status, 'sourceRefType', a.source_ref_type, 'sourceRefId', a.source_ref_id
  )), '[]'::jsonb) into v_accounts
  from billing.billing_account a
  where a.tenant_id = p_tenant_id and a.patient_id = p_patient_id and not a.is_deleted;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id, 'accountId', b.account_id, 'branchId', a.branch_id,
    'billNo', b.bill_no, 'status', b.status, 'billKind', b.bill_kind,
    'totalPaise', t.total_paise, 'duePaise', bal.due_paise
  ) order by b.created_on desc), '[]'::jsonb) into v_bills
  from billing.bill b
  join billing.billing_account a on a.id = b.account_id
  left join billing.bill_totals_v1 t on t.bill_id = b.id
  left join billing.bill_balance_v1 bal on bal.bill_id = b.id
  where a.tenant_id = p_tenant_id and a.patient_id = p_patient_id and not b.is_deleted and b.status <> 'cancelled_draft';
  return jsonb_build_object(
    'patientId', p_patient_id, 'advancePaise', coalesce(v_advance, 0),
    'accounts', v_accounts, 'bills', v_bills);
end;
$$;

-- --------------------------------------------------------------------- payments ----
create or replace function billing.collect_payment(p_tenant_id uuid, p_idem uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_existing uuid;
  v_account billing.billing_account%rowtype;
  v_kind text := coalesce(p_body ->> 'kind', 'payment');
  v_amount bigint := 0;
  v_cash bigint := 0;
  v_tender jsonb;
  v_alloc jsonb;
  v_alloc_sum bigint := 0;
  v_payment uuid;
  v_receipt text;
  v_session uuid := nullif(p_body ->> 'counterSessionId', '')::uuid;
begin
  if not billing.bypass_acl() then
    perform billing.assert_permission(p_tenant_id, 'billing.collect');
  end if;
  select id into v_existing from billing.payment
  where tenant_id = p_tenant_id and idempotency_key = p_idem and not is_deleted;
  if v_existing is not null then
    if (select amount_paise from billing.payment where id = v_existing)
       is distinct from coalesce((
         select sum((t ->> 'amountPaise')::bigint)
         from jsonb_array_elements(coalesce(p_body -> 'tenders', '[]'::jsonb)) t
       ), 0) then
      raise exception 'idempotency key reused with a different amount' using errcode = '23505';
    end if;
    return billing.receipt_json(v_existing);
  end if;
  select * into v_account from billing.billing_account
  where id = (p_body ->> 'accountId')::uuid and tenant_id = p_tenant_id and not is_deleted;
  if v_account.id is null then
    raise exception 'account not found' using errcode = 'P0002';
  end if;
  if v_kind not in ('payment', 'advance') then
    raise exception 'kind must be payment or advance' using errcode = '22023';
  end if;
  for v_tender in select * from jsonb_array_elements(coalesce(p_body -> 'tenders', '[]'::jsonb))
  loop
    v_amount := v_amount + (v_tender ->> 'amountPaise')::bigint;
    if v_tender ->> 'mode' = 'cash' then
      v_cash := v_cash + (v_tender ->> 'amountPaise')::bigint;
    end if;
  end loop;
  if v_amount <= 0 then
    raise exception 'a payment needs a tender' using errcode = '22023';
  end if;
  for v_alloc in select * from jsonb_array_elements(coalesce(p_body -> 'allocations', '[]'::jsonb))
  loop
    if (v_alloc ->> 'amountPaise')::bigint <= 0 then
      raise exception 'an allocation must be a positive amount' using errcode = '22023';
    end if;
    v_alloc_sum := v_alloc_sum + (v_alloc ->> 'amountPaise')::bigint;
  end loop;
  if v_kind = 'payment' and v_alloc_sum is distinct from v_amount then
    raise exception 'allocations must add up to the payment' using errcode = '22023';
  end if;
  if v_kind = 'advance' and v_alloc_sum <> 0 then
    raise exception 'an advance is not allocated to a bill' using errcode = '22023';
  end if;
  perform billing.assert_cash_ceiling(p_tenant_id, v_account.patient_id, v_account.branch_id, v_cash);
  if v_cash > 0 or v_session is not null then
    perform billing.assert_counter_session(p_tenant_id, v_session, v_account.branch_id, v_cash > 0);
  end if;
  v_receipt := billing.assign_number(p_tenant_id, v_account.branch_id, 'receipt');
  insert into billing.payment (tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise, counter_session_id)
  values (p_tenant_id, v_account.id, v_receipt, p_idem, v_kind, v_amount, v_session)
  returning id into v_payment;
  for v_tender in select * from jsonb_array_elements(p_body -> 'tenders')
  loop
    insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise, reference)
    values (p_tenant_id, v_payment, v_tender ->> 'mode', (v_tender ->> 'amountPaise')::bigint, nullif(v_tender ->> 'reference', ''));
  end loop;
  for v_alloc in select * from jsonb_array_elements(coalesce(p_body -> 'allocations', '[]'::jsonb))
  loop
    insert into billing.allocation (tenant_id, payment_id, bill_id, amount_paise)
    values (p_tenant_id, v_payment, (v_alloc ->> 'billId')::uuid, (v_alloc ->> 'amountPaise')::bigint);
  end loop;
  return billing.receipt_json(v_payment);
end;
$$;

create or replace function billing.insert_refund(
  p_tenant_id uuid, p_payment_id uuid, p_amount bigint, p_mode text, p_reference text,
  p_approval uuid, p_idem uuid, p_session uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_src billing.payment%rowtype;
  v_account billing.billing_account%rowtype;
  v_refunded bigint;
  v_net bigint;
  v_open bigint;
  v_reverse bigint;
  v_id uuid;
  v_receipt text;
  v_digital boolean;
  v_session uuid;
  v_row record;
  v_take bigint;
begin
  if not billing.bypass_acl()
     and not identity.has_tenant_permission(p_tenant_id, 'billing.refund')
     and not identity.has_tenant_permission(p_tenant_id, 'billing.approve') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  -- Row locks need UPDATE, which money tables no longer grant. The advisory lock
  -- serializes refunds of this receipt for the transaction.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('billing.payment:' || p_payment_id::text, 0));
  select * into v_src from billing.payment
  where id = p_payment_id and tenant_id = p_tenant_id and not is_deleted and kind <> 'refund';
  if v_src.id is null then
    raise exception 'payment not found' using errcode = 'P0002';
  end if;
  select coalesce(sum(amount_paise), 0) into v_refunded
  from billing.payment where refund_of_payment_id = p_payment_id and not is_deleted;
  if p_amount is null or p_amount <= 0 or p_amount > v_src.amount_paise - v_refunded then
    raise exception 'refund exceeds the amount still refundable' using errcode = '22023';
  end if;
  select * into v_account from billing.billing_account where id = v_src.account_id;
  v_digital := exists (
    select 1 from billing.payment_tender t
    where t.payment_id = p_payment_id and not t.is_deleted and t.mode <> 'cash');
  if p_mode = 'cash' and v_digital and not billing.caller_is_manager(p_tenant_id) and not billing.bypass_acl() then
    raise exception 'a cash refund of a digital payment needs a manager' using errcode = '42501';
  end if;
  if p_mode is null then
    select mode into p_mode from billing.payment_tender
    where payment_id = p_payment_id and not is_deleted
    order by amount_paise desc limit 1;
  end if;
  select coalesce(sum(amount_paise), 0) into v_net
  from billing.allocation where payment_id = p_payment_id and not is_deleted;
  v_open := v_src.amount_paise - v_refunded - v_net;
  v_reverse := greatest(p_amount - greatest(v_open, 0), 0);
  v_session := billing.refund_session(p_tenant_id, v_account.branch_id, p_mode, v_src.counter_session_id, p_session);
  v_receipt := billing.assign_number(p_tenant_id, v_account.branch_id, 'receipt');
  insert into billing.payment (
    tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise,
    counter_session_id, refund_of_payment_id, approval_id)
  values (p_tenant_id, v_src.account_id, v_receipt, p_idem, 'refund', p_amount, v_session, p_payment_id, p_approval)
  returning id into v_id;
  insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise, reference)
  values (p_tenant_id, v_id, p_mode, p_amount, p_reference);
  for v_row in
    select al.bill_id, sum(al.amount_paise) as net
    from billing.allocation al
    where al.payment_id = p_payment_id and not al.is_deleted
    group by al.bill_id
    having sum(al.amount_paise) > 0
    order by max(al.created_on) desc, al.bill_id desc
  loop
    exit when v_reverse <= 0;
    v_take := least(v_reverse, v_row.net);
    insert into billing.allocation (tenant_id, payment_id, bill_id, amount_paise)
    values (p_tenant_id, p_payment_id, v_row.bill_id, -v_take);
    v_reverse := v_reverse - v_take;
  end loop;
  if v_reverse > 0 then
    raise exception 'refund could not be reversed against the allocations' using errcode = '55000';
  end if;
  return v_id;
end;
$$;

comment on function billing.insert_refund(uuid, uuid, bigint, text, text, uuid, uuid, uuid) is
  'Writes a refund receipt and, when the original receipt was allocated, a negative allocation. Cash reduces the open drawer.';

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
begin
  perform billing.assert_permission(p_tenant_id, 'billing.refund');
  select * into v_src from billing.payment where id = p_payment_id and tenant_id = p_tenant_id and not is_deleted and kind <> 'refund';
  if v_src.id is null then
    raise exception 'payment not found' using errcode = 'P0002';
  end if;
  if v_amount is null then
    v_amount := v_src.amount_paise;
  end if;
  v_percent := case when v_src.amount_paise > 0 then round(v_amount * 10000.0 / v_src.amount_paise)::integer else null end;
  if v_mode is null then
    select mode into v_mode from billing.payment_tender where payment_id = p_payment_id and not is_deleted
    order by amount_paise desc limit 1;
  end if;
  v_digital := exists (
    select 1 from billing.payment_tender t where t.payment_id = p_payment_id and not t.is_deleted and t.mode <> 'cash');
  if billing.within_limit(p_tenant_id, 'refund', v_amount, v_percent)
     and not (v_mode = 'cash' and v_digital and not billing.caller_is_manager(p_tenant_id)) then
    insert into billing.approval_request (
      tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, approver_id, status, decided_at, payload)
    values (
      p_tenant_id, 'refund', 'payment', p_payment_id, v_amount, v_percent, audit.session_actor_id(), audit.session_actor_id(), 'approved', pg_catalog.now(),
      jsonb_build_object('paymentId', p_payment_id, 'amountPaise', v_amount, 'mode', v_mode, 'reference', p_body ->> 'reference', 'counterSessionId', v_session))
    returning id into v_approval;
    v_id := billing.insert_refund(
      p_tenant_id, p_payment_id, v_amount, v_mode, nullif(p_body ->> 'reference', ''), v_approval, gen_random_uuid(), v_session);
    return billing.receipt_json(v_id);
  end if;
  insert into billing.approval_request (
    tenant_id, action, subject_type, subject_id, amount_paise, percent_bp, requested_by, status, payload)
  values (
    p_tenant_id, 'refund', 'payment', p_payment_id, v_amount, v_percent, audit.session_actor_id(), 'pending',
    jsonb_build_object('paymentId', p_payment_id, 'amountPaise', v_amount, 'mode', v_mode, 'reference', p_body ->> 'reference', 'counterSessionId', v_session))
  returning id into v_approval;
  return jsonb_build_object('approvalId', v_approval, 'status', 'pending');
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
  if v_status = 'approved' and not billing.within_limit(p_tenant_id, v_req.action, v_req.amount_paise, v_req.percent_bp) then
    raise exception 'outside your approval limit' using errcode = '42501';
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

drop function billing.insert_refund(uuid, uuid, bigint, text, text, uuid, uuid);

create or replace function billing.cancel_draft(p_tenant_id uuid, p_bill_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_status text;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  select status into v_status from billing.bill where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_status is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  if v_status <> 'draft' then
    raise exception 'only a draft bill can be cancelled' using errcode = '55000';
  end if;
  if billing.allocated_paise(p_bill_id) <> 0 then
    raise exception 'a bill with a payment cannot be cancelled; refund the receipt' using errcode = '55000';
  end if;
  update billing.bill set status = 'cancelled_draft' where id = p_bill_id;
  return billing.bill_json(p_bill_id);
end;
$$;

-- Applies unallocated receipts (advances) for this patient onto one bill.
-- No new receipt: the original receipt number already exists. The new fact is an allocation.
create or replace function billing.apply_advance(p_tenant_id uuid, p_bill_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_bill billing.bill%rowtype;
  v_account billing.billing_account%rowtype;
  v_due bigint;
  v_advance bigint;
  v_amount bigint;
  v_left bigint;
  v_pay record;
  v_take bigint;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  select * into v_bill from billing.bill
  where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted
  for update;
  if v_bill.id is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  if v_bill.status not in ('draft', 'finalized') or v_bill.bill_kind = 'credit_note' then
    raise exception 'an advance applies to an open or finalized bill' using errcode = '55000';
  end if;
  select * into v_account from billing.billing_account where id = v_bill.account_id;
  perform billing.assert_branch(p_tenant_id, v_account.branch_id);
  select due_paise into v_due from billing.bill_balance_v1 where bill_id = p_bill_id;
  v_amount := nullif(p_body ->> 'amountPaise', '')::bigint;
  if v_amount is null then
    v_amount := v_due;
  end if;
  if v_due is null or v_due <= 0 or v_amount is null or v_amount <= 0 or v_amount > v_due then
    raise exception 'advance application is outside the amount due' using errcode = '22023';
  end if;
  select coalesce((
    select advance_paise from billing.patient_advance_v1
    where tenant_id = p_tenant_id and patient_id = v_account.patient_id
  ), 0) into v_advance;
  if v_amount > v_advance then
    raise exception 'that is more than the patient advance' using errcode = '22023';
  end if;
  v_left := v_amount;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('billing.advance:' || v_account.patient_id::text, 0));
  for v_pay in
    select p.id
    from billing.payment p
    join billing.billing_account a on a.id = p.account_id and not a.is_deleted
    where p.tenant_id = p_tenant_id
      and a.patient_id = v_account.patient_id
      and p.kind <> 'refund'
      and not p.is_deleted
    order by p.received_at, p.id
  loop
    exit when v_left <= 0;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('billing.payment:' || v_pay.id::text, 0));
    select p.amount_paise
        - coalesce((select sum(r.amount_paise) from billing.payment r
                    where r.refund_of_payment_id = p.id and not r.is_deleted), 0)
        - coalesce((select sum(al.amount_paise) from billing.allocation al
                    where al.payment_id = p.id and not al.is_deleted), 0)
      into v_take
    from billing.payment p
    where p.id = v_pay.id;
    if v_take is null or v_take <= 0 then
      continue;
    end if;
    v_take := least(v_left, v_take);
    insert into billing.allocation (tenant_id, payment_id, bill_id, amount_paise)
    values (p_tenant_id, v_pay.id, p_bill_id, v_take);
    v_left := v_left - v_take;
  end loop;
  if v_left <> 0 then
    raise exception 'the patient advance is no longer available' using errcode = '22023';
  end if;
  return billing.bill_json(p_bill_id);
end;
$$;

comment on function billing.apply_advance(uuid, uuid, jsonb) is
  'Allocates existing unallocated receipts to this bill, oldest first, up to the amount due. Does not issue a receipt.';

create or replace function billing.create_payment_link(p_tenant_id uuid, p_bill_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_bill billing.bill%rowtype;
  v_branch uuid;
  v_due bigint;
  v_id uuid;
  v_order text := gen_random_uuid()::text;
  v_channel text := coalesce(p_body ->> 'channel', 'link');
  v_session uuid := nullif(p_body ->> 'counterSessionId', '')::uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  select * into v_bill from billing.bill
  where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted;
  if v_bill.id is null or v_bill.status not in ('draft', 'finalized') then
    raise exception 'bill is not open for payment' using errcode = '55000';
  end if;
  select a.branch_id into v_branch from billing.billing_account a where a.id = v_bill.account_id;
  select due_paise into v_due from billing.bill_balance_v1 where bill_id = p_bill_id;
  if v_due is null or v_due <= 0 then
    raise exception 'nothing is due on this bill' using errcode = '22023';
  end if;
  if v_channel not in ('whatsapp', 'sms', 'qr', 'link') then
    raise exception 'channel must be whatsapp, sms, qr or link' using errcode = '22023';
  end if;
  if v_session is not null then
    perform billing.assert_counter_session(p_tenant_id, v_session, v_branch, false);
  end if;
  insert into billing.payment_link (tenant_id, bill_id, channel, provider_order_id, expires_at, counter_session_id)
  values (p_tenant_id, p_bill_id, v_channel, v_order, pg_catalog.now() + interval '2 days', v_session)
  returning id into v_id;
  return jsonb_build_object(
    'id', v_id, 'providerOrderId', v_order, 'channel', v_channel,
    'path', '/api/v1/billing-public/links/' || v_order);
end;
$$;

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
  if v_event is null or v_order is null then
    raise exception 'eventId and providerOrderId are required' using errcode = '22023';
  end if;
  if exists (
    select 1 from billing.provider_webhook_event e
    where e.provider = p_provider and e.event_id = v_event and not e.is_deleted
  ) then
    return jsonb_build_object('duplicate', true);
  end if;
  select * into v_link from billing.payment_link where provider_order_id = v_order and not is_deleted;
  if v_link.id is null then
    raise exception 'payment link not found' using errcode = 'P0002';
  end if;
  if v_status is distinct from 'paid' then
    insert into billing.provider_webhook_event (tenant_id, provider, event_id)
    values (v_link.tenant_id, p_provider, v_event);
    return jsonb_build_object('duplicate', false, 'applied', false);
  end if;
  select due_paise, account_id into v_due, v_account
  from billing.bill_balance_v1
  where bill_id = v_link.bill_id;
  if v_amount is distinct from v_due or v_due is null or v_due <= 0 then
    raise exception 'webhook amount does not match the amount due' using errcode = '22023';
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
  insert into billing.provider_webhook_event (tenant_id, provider, event_id)
  values (v_link.tenant_id, p_provider, v_event);
  return v_receipt || jsonb_build_object('duplicate', false, 'applied', true);
end;
$$;

revoke all on all functions in schema billing from public, anon, authenticated;
grant execute on all functions in schema billing to hms_svc_billing;
grant execute on function billing.public_link(text) to anon;
grant execute on function billing.apply_webhook(text, jsonb) to anon;
