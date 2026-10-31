-- #261: a partial refund of a finalized bill issues a value-based GST credit note (CGST Act s.34).
-- credit_note_for_refund used to split the refund across lines by quantity, which gave fractional
-- quantities (refused for whole-number services: "quantity must be a whole number for this
-- service") and rounded a small refund to quantity 0 (no credit note, no GST reversal).
-- Now each credit line credits a VALUE: the refund (tax inclusive) is shared across the bill's
-- lines by what is still creditable on each, and each share is split into taxable value and GST
-- at that line's own rate. The line is stored as quantity -1 at unit price = taxable value, with
-- credit_basis = 'value', so line_net / line_tax / bill_gross and every total stay unchanged.
-- line_credited_qty counts a value credit as its unit equivalent (taxable / unit price), so a
-- later quantity credit note or refund can never credit more than the line was billed.
-- Billing schema only. No data change: existing lines default to credit_basis = 'quantity'.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

alter table billing.bill_line
  add column if not exists credit_basis text not null default 'quantity';
alter table billing.bill_line drop constraint if exists bill_line_credit_basis;
alter table billing.bill_line add constraint bill_line_credit_basis check (
  credit_basis in ('quantity', 'value')
  and (credit_basis = 'quantity' or (quantity = -1 and reverses_line_id is not null)));
comment on column billing.bill_line.credit_basis is
  'quantity: a normal line or a credit of units. value (#261): a credit note line of quantity -1 whose unit_price_paise is the taxable value credited.';

create or replace function billing.line_credited_qty(p_line_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(case
    when l.credit_basis = 'value' then
      case when src.unit_price_paise > 0 then l.unit_price_paise::numeric / src.unit_price_paise else src.quantity end
    else -l.quantity end), 0)
  from billing.bill_line l
  join billing.bill cn on cn.id = l.bill_id
  join billing.bill_line src on src.id = l.reverses_line_id
  where l.reverses_line_id = p_line_id
    and not l.is_deleted and not cn.is_deleted
    and cn.bill_kind = 'credit_note' and cn.status = 'finalized'
$$;

-- Tax-inclusive value of a line still not credited (paise).
create or replace function billing.line_creditable_gross(p_line_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select greatest(
    billing.line_net(s.quantity, s.unit_price_paise) + billing.line_tax(s.quantity, s.unit_price_paise, s.tax_rate_bp)
    - coalesce((
      select sum(-(billing.line_net(l.quantity, l.unit_price_paise) + billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp)))
      from billing.bill_line l
      join billing.bill cn on cn.id = l.bill_id
      where l.reverses_line_id = s.id and not l.is_deleted and not cn.is_deleted
        and cn.bill_kind = 'credit_note' and cn.status = 'finalized'), 0), 0)::bigint
  from billing.bill_line s
  where s.id = p_line_id
$$;

create or replace function billing.credit_note_for_refund(p_tenant_id uuid, p_payment_id uuid, p_amount bigint)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_bill uuid;
  v_status text;
  v_allocated bigint;
  v_full boolean := false;
  v_line record;
  v_total_left bigint;
  v_target bigint;
  v_given bigint := 0;
  v_seen bigint := 0;
  v_share bigint;
  v_taxable bigint;
  v_note uuid;
  v_n int := 0;
  v_count int;
begin
  select al.bill_id into v_bill
  from billing.allocation al
  where al.payment_id = p_payment_id and not al.is_deleted
  group by al.bill_id
  having sum(al.amount_paise) > 0
  order by sum(al.amount_paise) desc, max(al.created_on) desc
  limit 1;
  if v_bill is null then
    return null;
  end if;
  select status into v_status from billing.bill
  where id = v_bill and tenant_id = p_tenant_id and not is_deleted
  for update;
  if v_status is null or v_status = 'cancelled_draft' then
    return null;
  end if;
  -- Unchanged rule: a partial refund of an open bill goes back on the bill (no credit note);
  -- a refund that clears every allocation of a draft finalizes it and credits it in full.
  if v_status = 'draft' then
    select coalesce(sum(a.amount_paise), 0) into v_allocated
    from billing.allocation a
    where a.bill_id = v_bill and not a.is_deleted;
    if p_amount is null or p_amount < v_allocated then
      return null;
    end if;
    perform billing.finalize_bill(p_tenant_id, v_bill);
    v_full := true;
  end if;
  if p_amount is null or p_amount <= 0 then
    return null;
  end if;
  select coalesce(sum(billing.line_creditable_gross(l.id)), 0), count(*) filter (where billing.line_creditable_gross(l.id) > 0)
  into v_total_left, v_count
  from billing.bill_line l
  where l.bill_id = v_bill and not l.is_deleted and l.quantity > 0;
  if v_total_left <= 0 then
    return null;
  end if;
  v_target := case when v_full then v_total_left else least(p_amount, v_total_left) end;

  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  for v_line in
    select l.id, l.service_item_id, l.price_list_item_id, l.practitioner_id, l.tax_rate_bp,
           billing.line_creditable_gross(l.id) as left_gross
    from billing.bill_line l
    where l.bill_id = v_bill and not l.is_deleted and l.quantity > 0
      and billing.line_creditable_gross(l.id) > 0
    order by l.line_no
  loop
    v_seen := v_seen + 1;
    -- Largest-remainder style: the last line takes what is left so the note equals the target.
    if v_seen = v_count then
      v_share := v_target - v_given;
    else
      v_share := round(v_target::numeric * v_line.left_gross / v_total_left)::bigint;
    end if;
    v_share := least(greatest(v_share, 0), v_line.left_gross);
    continue when v_share = 0;
    -- Split the tax-inclusive share into taxable value and GST at this line's rate.
    v_taxable := round(v_share::numeric * 10000 / (10000 + v_line.tax_rate_bp))::bigint;
    continue when v_taxable = 0;
    if v_note is null then
      insert into billing.bill (tenant_id, account_id, bill_kind, reverses_bill_id, payer_type)
      select p_tenant_id, b.account_id, 'credit_note', b.id, b.payer_type
      from billing.bill b where b.id = v_bill
      returning id into v_note;
    end if;
    v_n := v_n + 1;
    insert into billing.bill_line (
      tenant_id, bill_id, line_no, service_item_id, price_list_item_id, practitioner_id,
      quantity, unit_price_paise, tax_rate_bp, reverses_line_id, credit_basis)
    values (
      p_tenant_id, v_note, v_n, v_line.service_item_id, v_line.price_list_item_id, v_line.practitioner_id,
      -1, v_taxable, v_line.tax_rate_bp, v_line.id, 'value');
    v_given := v_given + billing.line_net(1, v_taxable) + billing.line_tax(1, v_taxable, v_line.tax_rate_bp);
  end loop;
  if v_note is null then
    return null;
  end if;
  perform billing.finalize_bill(p_tenant_id, v_note);
  return v_note;
end;
$$;

comment on function billing.credit_note_for_refund(uuid, uuid, bigint) is
  'Refund credit note (#261): value based (CGST s.34). Shares the refund across lines by creditable value, reverses GST at each line rate; quantity -1 lines with credit_basis value.';
