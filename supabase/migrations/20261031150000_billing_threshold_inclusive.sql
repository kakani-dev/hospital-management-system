-- #115: an amount AT the tenant's maker-checker threshold now needs a second approver (>=).
-- The threshold stays the per-tenant billing.approval_settings value (column default when no row).
-- #110: documents the GST rounding rule already enforced by billing.tax_split / bill totals.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.needs_checker(p_tenant_id uuid, p_amount bigint)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(p_amount, 0) > 0
     and coalesce(p_amount, 0) >= coalesce((
       select s.maker_checker_threshold_paise
       from billing.approval_settings s
       where s.tenant_id = p_tenant_id and not s.is_deleted
     ), 20000)
$$;

comment on function billing.needs_checker(uuid, bigint) is
  '#115: true when a positive amount is at or above the tenant maker-checker threshold (inclusive).';
comment on table billing.approval_settings is
  'One row per tenant. Amounts at or above the threshold (inclusive, #115) need a different approver. Cancel refunds the paid share (default 100%); no-show defaults to none.';
comment on function billing.tax_split(bigint, integer, text, text) is
  '#110: tax is rounded per line to the paisa (half away from zero) at the full rate; intra-state CGST gets the odd paisa (tax - tax/2), SGST tax/2, so CGST+SGST always equals the line tax. The bill total is rounded to the nearest rupee and the difference is shown as round-off.';
