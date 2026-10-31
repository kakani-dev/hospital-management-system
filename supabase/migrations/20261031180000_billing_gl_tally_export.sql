-- cross-schema: approved (audit.* triggers, identity.current_tenant_ids() in RLS, identity.has_tenant_permission and the published identity.branch_local_date_v1 read)
-- #62: GL / Tally export. Per-tenant ledger mapping + a voucher feed (sales, credit notes, receipts,
-- refunds) in double-entry form with GST split (CGST/SGST/IGST per rate), discount and round-off lines.
-- The database returns ledger KEYS and signed amounts (+ debit / - credit); the billing service maps
-- keys to the tenant's ledger names (tenant row, else config default) and renders Tally XML / CSV.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create table billing.gl_ledger_map (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references identity.tenants (id) on delete restrict,
  ledger_key    text not null,
  ledger_name   text not null,
  parent_group  text,
  created_on    timestamptz not null default now(),
  created_by    uuid not null,
  updated_on    timestamptz not null default now(),
  updated_by    uuid not null,
  is_deleted    boolean not null default false,
  constraint gl_ledger_map_key check (ledger_key ~ '^[a-z_]+(:[a-z0-9_-]{1,40})?$'),
  constraint gl_ledger_map_name check (char_length(ledger_name) between 1 and 100 and ledger_name = btrim(ledger_name)),
  constraint gl_ledger_map_group check (parent_group is null or (char_length(parent_group) between 1 and 100 and parent_group = btrim(parent_group)))
);
create unique index gl_ledger_map_tenant_key on billing.gl_ledger_map (tenant_id, ledger_key) where not is_deleted;
comment on table billing.gl_ledger_map is
  '#62: tenant override of a GL/Tally ledger name per key (party:*, sales:*, gst:*, discount, round_off, tender:*, payacct:*). No row = config default.';

create table billing.gl_export_log (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references identity.tenants (id) on delete restrict,
  branch_id      uuid,
  from_date      date not null,
  to_date        date not null,
  format         text not null,
  voucher_count  integer not null,
  debit_paise    bigint not null,
  created_on     timestamptz not null default now(),
  created_by     uuid not null,
  updated_on     timestamptz not null default now(),
  updated_by     uuid not null,
  is_deleted     boolean not null default false,
  constraint gl_export_log_range check (to_date >= from_date),
  constraint gl_export_log_format check (format in ('xml', 'csv'))
);
create index gl_export_log_tenant on billing.gl_export_log (tenant_id, to_date desc);
comment on table billing.gl_export_log is '#62: who exported which period (re-export warning). Re-imports are safe: vouchers carry a stable REMOTEID.';

create trigger gl_ledger_map_audit_columns before insert or update on billing.gl_ledger_map
  for each row execute function audit.stamp_audit_columns();
create trigger gl_ledger_map_tenant_immutable before update on billing.gl_ledger_map
  for each row execute function audit.prevent_tenant_change();
create trigger gl_ledger_map_audit_log after insert or update or delete on billing.gl_ledger_map
  for each row execute function audit.log_row_change();
create trigger gl_export_log_audit_columns before insert or update on billing.gl_export_log
  for each row execute function audit.stamp_audit_columns();
create trigger gl_export_log_tenant_immutable before update on billing.gl_export_log
  for each row execute function audit.prevent_tenant_change();
create trigger gl_export_log_audit_log after insert or update or delete on billing.gl_export_log
  for each row execute function audit.log_row_change();

alter table billing.gl_ledger_map enable row level security;
alter table billing.gl_export_log enable row level security;
revoke all on billing.gl_ledger_map, billing.gl_export_log from anon, authenticated, public;
grant select, insert, update on billing.gl_ledger_map to hms_svc_billing;
grant select, insert on billing.gl_export_log to hms_svc_billing;
grant all on billing.gl_ledger_map, billing.gl_export_log to service_role;
create policy gl_ledger_map_tenant on billing.gl_ledger_map for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids()))
  with check (tenant_id in (select identity.current_tenant_ids()));
create policy gl_export_log_tenant on billing.gl_export_log for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids()))
  with check (tenant_id in (select identity.current_tenant_ids()));

-- ------------------------------------------------------------------ mapping ----
create or replace function billing.gl_ledger_map_get(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_tenant_id is null or (select auth.uid()) is null
     or not identity.has_tenant_permission(p_tenant_id, 'billing.earnings') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'overrides', coalesce((
      select jsonb_agg(jsonb_build_object('key', m.ledger_key, 'name', m.ledger_name, 'group', m.parent_group) order by m.ledger_key)
        from billing.gl_ledger_map m where m.tenant_id = p_tenant_id and not m.is_deleted), '[]'::jsonb),
    'paymentAccounts', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'mode', a.mode, 'label', a.label) order by a.mode, a.label)
        from billing.payment_account a where a.tenant_id = p_tenant_id and not a.is_deleted and a.is_active), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(c.category order by c.category) from billing.service_category c), '[]'::jsonb),
    'gstRates', coalesce((
      select jsonb_agg(distinct t.rate_bp order by t.rate_bp)
        from billing.tax_code t where t.tenant_id = p_tenant_id and not t.is_deleted and not t.is_exempt and t.rate_bp > 0), '[]'::jsonb),
    'lastExport', (
      select jsonb_build_object('from', e.from_date, 'to', e.to_date, 'format', e.format, 'at', e.created_on, 'vouchers', e.voucher_count)
        from billing.gl_export_log e where e.tenant_id = p_tenant_id and not e.is_deleted
       order by e.created_on desc limit 1));
end;
$$;

-- p_items: [{key, name, group}] ; an empty/null name removes the override (back to default).
create or replace function billing.gl_ledger_map_set(p_tenant_id uuid, p_items jsonb)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r record;
  v_n integer := 0;
begin
  if p_tenant_id is null or (select auth.uid()) is null
     or not identity.has_tenant_permission(p_tenant_id, 'billing.earnings') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'items must be an array' using errcode = '22023';
  end if;
  for r in
    select btrim(x->>'key') as k, nullif(btrim(coalesce(x->>'name', '')), '') as n, nullif(btrim(coalesce(x->>'group', '')), '') as g
      from jsonb_array_elements(p_items) x
  loop
    if r.k is null or r.k !~ '^[a-z_]+(:[a-z0-9_-]{1,40})?$' then
      raise exception 'invalid ledger key' using errcode = '22023';
    end if;
    if r.n is null then
      update billing.gl_ledger_map set is_deleted = true
       where tenant_id = p_tenant_id and ledger_key = r.k and not is_deleted;
    else
      update billing.gl_ledger_map set ledger_name = r.n, parent_group = r.g
       where tenant_id = p_tenant_id and ledger_key = r.k and not is_deleted;
      if not found then
        insert into billing.gl_ledger_map (tenant_id, ledger_key, ledger_name, parent_group)
        values (p_tenant_id, r.k, r.n, r.g);
      end if;
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- ----------------------------------------------------------------- vouchers ----
-- Branch-local dates. Drafts/cancelled drafts never export. Zero-value vouchers are skipped
-- (counted) because Tally rejects them. Amounts: + debit, - credit; each voucher sums to 0.
create or replace function billing.gl_vouchers(p_tenant_id uuid, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_utc_from timestamptz;
  v_utc_to timestamptz;
  v_out jsonb;
begin
  if p_tenant_id is null or (select auth.uid()) is null
     or not identity.has_tenant_permission(p_tenant_id, 'billing.earnings') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then
    raise exception 'from and to are required' using errcode = '22023';
  end if;
  if p_to < p_from then
    raise exception 'to is before from' using errcode = '22023';
  end if;
  if (p_to - p_from) > 399 then
    raise exception 'the period is longer than 400 days' using errcode = '22023';
  end if;
  v_utc_from := (p_from - 2)::timestamp at time zone 'UTC';
  v_utc_to := (p_to + 3)::timestamp at time zone 'UTC';

  with bills as (
    select b.id, b.bill_kind, b.bill_no, b.payer_type, b.supplier_state_code, b.pos_state_code,
           a.branch_id, identity.branch_local_date_v1(a.branch_id, b.finalized_at) as d,
           ob.bill_no as against_no, t.discount_paise, t.round_off_paise, t.total_paise
      from billing.bill b
      join billing.billing_account a on a.id = b.account_id and a.tenant_id = b.tenant_id
      join billing.bill_totals_v1 t on t.bill_id = b.id
      left join billing.bill ob on ob.id = b.reverses_bill_id
     where b.tenant_id = p_tenant_id and not b.is_deleted and b.status = 'finalized'
       and b.finalized_at >= v_utc_from and b.finalized_at < v_utc_to
       and (p_branch_id is null or a.branch_id = p_branch_id)
  ), bills_in as (
    select * from bills where d between p_from and p_to
  ), lines as (
    select l.bill_id, coalesce(si.category, 'other') as category, l.tax_rate_bp,
           billing.line_net(l.quantity, l.unit_price_paise) as net,
           billing.tax_split(billing.line_tax(l.quantity, l.unit_price_paise, l.tax_rate_bp), l.tax_rate_bp,
                             bi.supplier_state_code, bi.pos_state_code) as tx
      from bills_in bi
      join billing.bill_line l on l.bill_id = bi.id and not l.is_deleted
      left join billing.service_item si on si.id = l.service_item_id
  ), bill_entries as (
    select bill_id, 'sales:' || category as k, null::integer as rate, -sum(net) as amt from lines group by 1, 2
    union all select bill_id, 'gst:cgst', (tx->>'cgstRateBp')::integer, -sum((tx->>'cgstPaise')::bigint) from lines group by 1, 3
    union all select bill_id, 'gst:sgst', (tx->>'sgstRateBp')::integer, -sum((tx->>'sgstPaise')::bigint) from lines group by 1, 3
    union all select bill_id, 'gst:igst', (tx->>'igstRateBp')::integer, -sum((tx->>'igstPaise')::bigint) from lines group by 1, 3
    union all select id, 'discount', null, discount_paise from bills_in
    union all select id, 'round_off', null, -round_off_paise from bills_in
    union all select id, 'party:' || payer_type, null, total_paise from bills_in
  ), bill_v as (
    select bi.id, bi.d, bi.bill_no, bi.bill_kind, bi.against_no, bi.branch_id, bi.total_paise,
           coalesce((select jsonb_agg(jsonb_build_object('key', e.k, 'rateBp', e.rate, 'amountPaise', e.amt) order by e.amt desc, e.k)
                       from bill_entries e where e.bill_id = bi.id and e.amt <> 0), '[]'::jsonb) as entries
      from bills_in bi
  ), pays as (
    select p.id, p.kind, p.receipt_no, a.branch_id, identity.branch_local_date_v1(a.branch_id, p.received_at) as d,
           rp.receipt_no as against_no, p.amount_paise,
           -- party follows the bill(s) the money was allocated to (corporate/TPA settlements), else the patient
           coalesce((select min(ab.payer_type) from billing.allocation al
                       join billing.bill ab on ab.id = al.bill_id
                      where al.payment_id = coalesce(p.refund_of_payment_id, p.id) and not al.is_deleted
                     having count(distinct ab.payer_type) = 1), 'self') as payer_type
      from billing.payment p
      join billing.billing_account a on a.id = p.account_id and a.tenant_id = p.tenant_id
      left join billing.payment rp on rp.id = p.refund_of_payment_id
     where p.tenant_id = p_tenant_id and not p.is_deleted
       and p.received_at >= v_utc_from and p.received_at < v_utc_to
       and (p_branch_id is null or a.branch_id = p_branch_id)
  ), pays_in as (
    select * from pays where d between p_from and p_to
  ), pay_entries as (
    select pi.id as payment_id,
           case when t.payment_account_id is not null then 'payacct:' || t.payment_account_id::text else 'tender:' || t.mode end as k,
           t.mode,
           case when pi.kind = 'refund' then -t.amount_paise else t.amount_paise end as amt
      from pays_in pi join billing.payment_tender t on t.payment_id = pi.id and not t.is_deleted
  ), pay_v as (
    select pi.id, pi.d, pi.receipt_no, pi.kind, pi.against_no, pi.branch_id, pi.payer_type,
           coalesce((select sum(abs(e.amt)) from pay_entries e where e.payment_id = pi.id), 0) as total_paise,
           coalesce((select bool_and(e.mode = 'credit') from pay_entries e where e.payment_id = pi.id), false) as all_credit,
           (select jsonb_agg(x order by (x->>'amountPaise')::bigint desc, x->>'key') from (
              select jsonb_build_object('key', e.k, 'mode', e.mode, 'amountPaise', sum(e.amt)) as x
                from pay_entries e where e.payment_id = pi.id group by e.k, e.mode
              union all
              select jsonb_build_object('key', 'party:' || pi.payer_type, 'amountPaise', -sum(e.amt))
                from pay_entries e where e.payment_id = pi.id having count(*) > 0) s) as entries
      from pays_in pi
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'branchId', p_branch_id,
    'vouchers', coalesce((select jsonb_agg(v order by v->>'date', v->>'type', v->>'number') from (
        select jsonb_build_object('id', id, 'type', case when bill_kind = 'credit_note' then 'credit_note' else 'sales' end,
                 'number', bill_no, 'date', d, 'against', against_no, 'branchId', branch_id, 'entries', entries) as v
          from bill_v where total_paise <> 0 or jsonb_array_length(entries) > 0
        union all
        select jsonb_build_object('id', id,
                 'type', case when kind = 'refund' then 'refund' when all_credit then 'journal' else 'receipt' end,
                 'number', receipt_no, 'date', d, 'against', against_no, 'branchId', branch_id, 'advance', kind = 'advance',
                 'entries', entries)
          from pay_v where total_paise <> 0) q), '[]'::jsonb),
    'skippedZero', (select count(*) from bill_v where total_paise = 0 and jsonb_array_length(entries) = 0)
                 + (select count(*) from pay_v where total_paise = 0))
  into v_out;
  return v_out;
end;
$$;

create or replace function billing.gl_export_record(
  p_tenant_id uuid, p_from date, p_to date, p_branch_id uuid, p_format text, p_vouchers integer, p_debit bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_prior jsonb;
begin
  if p_tenant_id is null or (select auth.uid()) is null
     or not identity.has_tenant_permission(p_tenant_id, 'billing.earnings') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select jsonb_build_object('from', e.from_date, 'to', e.to_date, 'at', e.created_on, 'format', e.format)
    into v_prior
    from billing.gl_export_log e
   where e.tenant_id = p_tenant_id and not e.is_deleted
     and e.from_date <= p_to and e.to_date >= p_from
     and e.branch_id is not distinct from p_branch_id
   order by e.created_on desc limit 1;
  insert into billing.gl_export_log (tenant_id, branch_id, from_date, to_date, format, voucher_count, debit_paise)
  values (p_tenant_id, p_branch_id, p_from, p_to, p_format, p_vouchers, p_debit);
  return v_prior;
end;
$$;

revoke all on function billing.gl_ledger_map_get(uuid), billing.gl_ledger_map_set(uuid, jsonb),
  billing.gl_vouchers(uuid, date, date, uuid), billing.gl_export_record(uuid, date, date, uuid, text, integer, bigint)
  from public, anon, authenticated;
grant execute on function billing.gl_ledger_map_get(uuid), billing.gl_ledger_map_set(uuid, jsonb),
  billing.gl_vouchers(uuid, date, date, uuid), billing.gl_export_record(uuid, date, date, uuid, text, integer, bigint)
  to hms_svc_billing, service_role;
