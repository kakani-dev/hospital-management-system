-- #143: overpaying a bill, or paying a bill with nothing due, returned 500. The bound is checked by
-- the deferred constraint trigger billing.allocation_bound, which fires at COMMIT, after the API has
-- left its database error handler, so the 23514 became a 500. record_payment now checks each
-- allocation before anything is written and raises 22023 (400) with the PAY-005 / PAY-006 messages.
-- The trigger stays as the backstop, and is made immediate for this call so a race still maps to 4xx.
-- Billing schema only. Same signature, owner and grants.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.assert_payment_allocations(p_tenant_id uuid, p_account_id uuid, p_body jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_alloc record;
  v_bill billing.bill%rowtype;
  v_patient uuid;
  v_due bigint;
begin
  if p_body -> 'allocations' is null or jsonb_typeof(p_body -> 'allocations') = 'null' then
    return;
  end if;
  if jsonb_typeof(p_body -> 'allocations') <> 'array' then
    raise exception 'allocations must be a list of {billId, amountPaise}' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_body -> 'allocations') a
    where jsonb_typeof(a) <> 'object'
       or coalesce(a ->> 'billId', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception 'each allocation needs the billId of a bill on this account' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_body -> 'allocations') a
    where jsonb_typeof(a -> 'amountPaise') <> 'number'
       or (a ->> 'amountPaise') !~ '^[0-9]+$' or (a ->> 'amountPaise')::numeric > 9e15) then
    raise exception 'an allocation must be a positive amount' using errcode = '22023';
  end if;
  select patient_id into v_patient from billing.billing_account where id = p_account_id;
  for v_alloc in
    select (a ->> 'billId')::uuid as bill_id, sum((a ->> 'amountPaise')::bigint) as amount
    from jsonb_array_elements(p_body -> 'allocations') a
    group by 1 order by 1
  loop
    -- Lock the bill so two payments cannot both pass the check.
    select b.* into v_bill from billing.bill b
    join billing.billing_account ba on ba.id = b.account_id
    where b.id = v_alloc.bill_id and b.tenant_id = p_tenant_id and not b.is_deleted
      and ba.patient_id = v_patient
    for update of b;
    if v_bill.id is null then
      raise exception 'allocation bill not found for this patient' using errcode = '22023';
    end if;
    if v_bill.status not in ('draft', 'finalized') or v_bill.bill_kind = 'credit_note' then
      raise exception 'bill is not open for payment' using errcode = '22023';
    end if;
    select due_paise into v_due from billing.bill_balance_v1 where bill_id = v_bill.id;
    v_due := coalesce(v_due, 0);
    if v_due <= 0 then
      raise exception 'nothing is due on this bill' using errcode = '22023';
    end if;
    if v_alloc.amount > v_due then
      raise exception 'allocations exceed the bill total: % is due', to_char(v_due / 100.0, 'FM"₹"999999999990.00')
        using errcode = '22023';
    end if;
  end loop;
end;
$$;

revoke all on function billing.assert_payment_allocations(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function billing.assert_payment_allocations(uuid, uuid, jsonb) to hms_svc_billing;

create or replace function billing.record_payment(p_tenant_id uuid, p_idem uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_branch uuid;
  v_account uuid;
  v_result jsonb;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  if coalesce(p_body ->> 'accountId', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select id, branch_id into v_account, v_branch from billing.billing_account
    where id = (p_body ->> 'accountId')::uuid and tenant_id = p_tenant_id and not is_deleted;
  end if;
  if exists (select 1 from billing.payment where tenant_id = p_tenant_id and idempotency_key = p_idem and not is_deleted) then
    -- Replay: return the original receipt (even when its account is now hidden); no new checks.
    if v_branch is not null then
      perform billing.assert_branch(p_tenant_id, v_branch);
    end if;
    return billing.collect_payment(p_tenant_id, p_idem, p_body);
  end if;
  if v_branch is null then
    raise exception 'account not found' using errcode = 'P0002';
  end if;
  perform billing.assert_branch(p_tenant_id, v_branch);
  perform billing.assert_payment_allocations(p_tenant_id, v_account, p_body);
  v_result := billing.collect_payment(p_tenant_id, p_idem, p_body);
  -- Run the deferred bound check now, inside this call, so any breach is a 4xx and not a COMMIT 500.
  set constraints billing.allocation_bound immediate;
  set constraints billing.allocation_bound deferred;
  return v_result;
end;
$$;
