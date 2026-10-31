-- #269: a refund credit note totals exactly the refund. bill_totals_v1 rounded every document to the
-- rupee, so a 1 paisa refund produced a 0.00 note and a 66.66 refund a 67.00 note. Refund notes now
-- carry their own round-off (0 for a partial refund; the paid-amount rounding for a full refund).
-- Bills and quantity credit notes keep rupee rounding.

set local lock_timeout = '5s';
set local statement_timeout = '120s';

alter table billing.bill add column round_off_override_paise bigint;
alter table billing.bill add constraint bill_round_off_override_chk
  check (round_off_override_paise is null
         or (bill_kind = 'credit_note' and round_off_override_paise between -99 and 99));
comment on column billing.bill.round_off_override_paise is
  'Fixed round-off for a refund credit note (#269); null = round the total to the nearest rupee.';

create or replace view billing.bill_totals_v1
with (security_invoker = true) as
select b.id as bill_id,
       b.tenant_id,
       b.account_id,
       coalesce(g.net_paise, 0)::bigint as net_paise,
       coalesce(g.tax_paise, 0)::bigint as tax_paise,
       billing.discount_total(b.id) as discount_paise,
       (coalesce(g.net_paise, 0) + coalesce(g.tax_paise, 0) - billing.discount_total(b.id))::bigint as exact_paise,
       coalesce(b.round_off_override_paise,
         round((coalesce(g.net_paise, 0) + coalesce(g.tax_paise, 0) - billing.discount_total(b.id)) / 100.0, 0) * 100
         - (coalesce(g.net_paise, 0) + coalesce(g.tax_paise, 0) - billing.discount_total(b.id))
       )::bigint as round_off_paise,
       (coalesce(g.net_paise, 0) + coalesce(g.tax_paise, 0) - billing.discount_total(b.id)
        + coalesce(b.round_off_override_paise,
            round((coalesce(g.net_paise, 0) + coalesce(g.tax_paise, 0) - billing.discount_total(b.id)) / 100.0, 0) * 100
            - (coalesce(g.net_paise, 0) + coalesce(g.tax_paise, 0) - billing.discount_total(b.id))))::bigint as total_paise
from billing.bill b
left join lateral (
  select sum(billing.line_net(l.quantity, l.unit_price_paise))::bigint as net_paise,
         sum(billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp))::bigint as tax_paise
  from billing.bill_line l
  where l.bill_id = b.id and not l.is_deleted
) g on true
where not b.is_deleted;

comment on view billing.bill_totals_v1 is
  'Computed bill total. Round-off is to the nearest rupee (half away from zero) and is not a stored line, except a refund credit note, which uses its fixed round-off so it equals the refund (#269).';

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
  v_round bigint;
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
  -- #269: the note's total is the refund, not the gross rounded to the rupee. The gap is at most the
  -- rupee rounding of what was paid (a full refund of a rounded bill, up or down); otherwise exact.
  v_round := v_given - p_amount;
  if abs(v_round) > 99 then
    v_round := 0;  -- e.g. a draft refunded in full after a part payment: the note credits the whole bill
  end if;
  update billing.bill set round_off_override_paise = v_round where id = v_note;
  perform billing.finalize_bill(p_tenant_id, v_note);
  return v_note;
end;
$$;
