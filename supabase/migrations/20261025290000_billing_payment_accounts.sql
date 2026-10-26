-- Per-branch payment accounts (issue #63): bank account, UPI VPA, card terminal MID/TID.
-- One active default per (branch, mode). Tenders record the account that received them.
-- No full account numbers are stored: bank accounts keep last 4 digits only.
-- cross-schema: approved (audit.* trigger functions for the standard audit columns, and
-- identity.current_tenant_ids / current_branch_ids / branch_local_date_v1 for RLS and branch days;
-- the same read-only contracts every billing migration uses).

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table billing.payment_account (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null,
  branch_id     uuid not null,
  mode          text not null,
  label         text not null,
  bank_name     text,
  account_last4 text,
  ifsc          text,
  vpa           text,
  payee_name    text,
  mid           text,
  tid           text,
  is_default    boolean not null default false,
  is_active     boolean not null default true,
  created_on    timestamptz not null default now(),
  created_by    uuid not null,
  updated_on    timestamptz not null default now(),
  updated_by    uuid not null,
  is_deleted    boolean not null default false,
  identity_key  text generated always as (
    case mode
      when 'bank' then ifsc || ':' || account_last4
      when 'upi' then lower(vpa)
      when 'card' then mid || ':' || tid
    end) stored,
  constraint payment_account_mode check (mode in ('bank', 'upi', 'card')),
  constraint payment_account_label check (char_length(btrim(label)) between 1 and 120),
  constraint payment_account_bank check (mode <> 'bank' or (
    account_last4 ~ '^[0-9]{4}$' and ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'
    and char_length(btrim(coalesce(bank_name, ''))) between 1 and 120)),
  constraint payment_account_upi check (mode <> 'upi' or vpa ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,254}@[A-Za-z][A-Za-z0-9]{1,63}$'),
  constraint payment_account_card check (mode <> 'card' or (mid ~ '^[A-Za-z0-9]{1,20}$' and tid ~ '^[A-Za-z0-9]{1,16}$')),
  constraint payment_account_default_active check (not is_default or (is_active and not is_deleted))
);
comment on table billing.payment_account is
  'Branch payment accounts. Bank rows keep last 4 digits only; never a full account number.';

-- The race guard: two concurrent "make default" calls cannot both commit.
create unique index payment_account_one_default on billing.payment_account (tenant_id, branch_id, mode)
  where is_default and not is_deleted;
-- The double-submit guard: the same VPA / bank / terminal is one row per branch.
create unique index payment_account_identity on billing.payment_account (tenant_id, branch_id, mode, identity_key)
  where not is_deleted;
create index payment_account_branch_idx on billing.payment_account (tenant_id, branch_id) where not is_deleted;

create trigger payment_account_audit_columns before insert or update on billing.payment_account
  for each row execute function audit.stamp_audit_columns();
create trigger payment_account_tenant_immutable before update on billing.payment_account
  for each row execute function audit.prevent_tenant_change();
create trigger payment_account_audit_log after insert or update or delete on billing.payment_account
  for each row execute function audit.log_row_change();
alter table billing.payment_account enable row level security;
grant select, insert, update on billing.payment_account to hms_svc_billing;
revoke delete on billing.payment_account from hms_svc_billing, anon, authenticated;
revoke all on billing.payment_account from anon, authenticated;

create policy payment_account_branch on billing.payment_account for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and branch_id in (select identity.current_branch_ids(tenant_id)))
  with check (tenant_id in (select identity.current_tenant_ids())
         and branch_id in (select identity.current_branch_ids(tenant_id)));

alter table billing.payment_tender add column payment_account_id uuid references billing.payment_account (id);
create index payment_tender_account_idx on billing.payment_tender (payment_account_id) where payment_account_id is not null;
comment on column billing.payment_tender.payment_account_id is
  'Account that received this tender. Null for cash/credit, or when the branch had no account for the mode.';

-- ------------------------------------------------------------ helpers ----

create or replace function billing.payment_account_json(p billing.payment_account)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p.id, 'branchId', p.branch_id, 'mode', p.mode, 'label', p.label,
    'bankName', p.bank_name,
    'maskedAccount', case when p.account_last4 is not null then 'XXXX' || p.account_last4 end,
    'ifsc', p.ifsc, 'vpa', p.vpa, 'payeeName', p.payee_name, 'mid', p.mid, 'tid', p.tid,
    'isDefault', p.is_default, 'isActive', p.is_active, 'updatedOn', p.updated_on);
$$;

-- Serialises default changes for one (branch, mode); the unique index is the backstop.
create or replace function billing.lock_account_slot(p_tenant_id uuid, p_branch_id uuid, p_mode text)
returns void
language sql
set search_path = ''
as $$
  select pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_tenant_id::text || p_branch_id::text || p_mode, 63));
$$;

-- Promote the oldest active account when a slot has no default.
create or replace function billing.ensure_account_default(p_tenant_id uuid, p_branch_id uuid, p_mode text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from billing.payment_account
                 where tenant_id = p_tenant_id and branch_id = p_branch_id and mode = p_mode
                   and is_default and not is_deleted) then
    update billing.payment_account set is_default = true
    where id = (select id from billing.payment_account
                where tenant_id = p_tenant_id and branch_id = p_branch_id and mode = p_mode
                  and is_active and not is_deleted
                order by created_on, id limit 1);
  end if;
end;
$$;

create or replace function billing.payment_accounts(p_tenant_id uuid, p_branch_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  return coalesce((
    select jsonb_agg(billing.payment_account_json(p) order by p.mode, not p.is_default, p.created_on)
    from billing.payment_account p
    where p.tenant_id = p_tenant_id and p.branch_id = p_branch_id and not p.is_deleted
  ), '[]'::jsonb);
end;
$$;

-- Create. A repeat of the same VPA / bank / terminal returns the existing row (double-submit safe).
create or replace function billing.add_payment_account(p_tenant_id uuid, p_branch_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_mode text := p_body ->> 'mode';
  v_row billing.payment_account%rowtype;
  v_number text := regexp_replace(coalesce(p_body ->> 'accountNumber', p_body ->> 'accountLast4', ''), '\D', '', 'g');
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  if v_mode is null or v_mode not in ('bank', 'upi', 'card') then
    raise exception 'mode must be bank, upi or card' using errcode = '22023';
  end if;
  if v_mode = 'bank' and char_length(v_number) < 4 then
    raise exception 'account number needs at least 4 digits' using errcode = '22023';
  end if;
  if v_mode = 'bank' and upper(btrim(coalesce(p_body ->> 'ifsc', ''))) !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then
    raise exception 'IFSC must be 4 letters, 0, then 6 letters or digits' using errcode = '22023';
  end if;
  if v_mode = 'upi' and btrim(coalesce(p_body ->> 'vpa', '')) !~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,254}@[A-Za-z][A-Za-z0-9]{1,63}$' then
    raise exception 'UPI ID must look like name@bank' using errcode = '22023';
  end if;
  perform billing.lock_account_slot(p_tenant_id, p_branch_id, v_mode);
  begin
    insert into billing.payment_account (
      tenant_id, branch_id, mode, label, bank_name, account_last4, ifsc, vpa, payee_name, mid, tid)
    values (
      p_tenant_id, p_branch_id, v_mode, btrim(coalesce(p_body ->> 'label', '')),
      case when v_mode = 'bank' then nullif(btrim(p_body ->> 'bankName'), '') end,
      case when v_mode = 'bank' then right(v_number, 4) end,
      case when v_mode = 'bank' then upper(btrim(p_body ->> 'ifsc')) end,
      case when v_mode = 'upi' then lower(btrim(p_body ->> 'vpa')) end,
      case when v_mode = 'upi' then nullif(btrim(p_body ->> 'payeeName'), '') end,
      case when v_mode = 'card' then upper(btrim(p_body ->> 'mid')) end,
      case when v_mode = 'card' then upper(btrim(p_body ->> 'tid')) end)
    returning * into v_row;
  exception
    when unique_violation then
      select * into v_row from billing.payment_account
      where tenant_id = p_tenant_id and branch_id = p_branch_id and mode = v_mode and not is_deleted
        and identity_key = case v_mode
          when 'bank' then upper(btrim(p_body ->> 'ifsc')) || ':' || right(v_number, 4)
          when 'upi' then lower(btrim(p_body ->> 'vpa'))
          else upper(btrim(p_body ->> 'mid')) || ':' || upper(btrim(p_body ->> 'tid')) end;
      return billing.payment_account_json(v_row);
    when check_violation then
      raise exception 'payment account details are invalid' using errcode = '22023';
  end;
  if coalesce((p_body ->> 'isDefault')::boolean, false) then
    update billing.payment_account set is_default = false
    where tenant_id = p_tenant_id and branch_id = p_branch_id and mode = v_mode and is_default and not is_deleted;
    update billing.payment_account set is_default = true where id = v_row.id;
  end if;
  perform billing.ensure_account_default(p_tenant_id, p_branch_id, v_mode);
  select * into v_row from billing.payment_account where id = v_row.id;
  return billing.payment_account_json(v_row);
end;
$$;

-- Update: label, isActive, isDefault. Identity fields are immutable (add a new account instead).
create or replace function billing.update_payment_account(p_tenant_id uuid, p_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_row billing.payment_account%rowtype;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  select * into v_row from billing.payment_account where id = p_id and tenant_id = p_tenant_id and not is_deleted;
  if v_row.id is null then
    raise exception 'payment account not found' using errcode = 'P0002';
  end if;
  perform billing.assert_branch(p_tenant_id, v_row.branch_id);
  perform billing.lock_account_slot(p_tenant_id, v_row.branch_id, v_row.mode);
  select * into v_row from billing.payment_account where id = p_id for update;
  if p_body ? 'label' then
    if char_length(btrim(coalesce(p_body ->> 'label', ''))) not between 1 and 120 then
      raise exception 'label must be 1 to 120 characters' using errcode = '22023';
    end if;
    update billing.payment_account set label = btrim(p_body ->> 'label') where id = p_id;
  end if;
  if p_body ? 'isActive' and not (p_body ->> 'isActive')::boolean then
    update billing.payment_account set is_active = false, is_default = false where id = p_id;
  elsif p_body ? 'isActive' then
    update billing.payment_account set is_active = true where id = p_id;
  end if;
  if coalesce((p_body ->> 'isDefault')::boolean, false) then
    if not (select is_active from billing.payment_account where id = p_id) then
      raise exception 'an inactive account cannot be the default' using errcode = '22023';
    end if;
    update billing.payment_account set is_default = false
    where tenant_id = p_tenant_id and branch_id = v_row.branch_id and mode = v_row.mode
      and is_default and id <> p_id and not is_deleted;
    update billing.payment_account set is_default = true where id = p_id;
  end if;
  perform billing.ensure_account_default(p_tenant_id, v_row.branch_id, v_row.mode);
  select * into v_row from billing.payment_account where id = p_id;
  return billing.payment_account_json(v_row);
end;
$$;

-- Soft delete. Old tenders keep their reference; the next active account becomes default.
-- Security definer because only the table owner may flip is_deleted; tenant, permission and
-- branch are checked explicitly from the session first.
create or replace function billing.delete_payment_account(p_tenant_id uuid, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row billing.payment_account%rowtype;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.pricelist_manage');
  select * into v_row from billing.payment_account where id = p_id and tenant_id = p_tenant_id and not is_deleted;
  if v_row.id is null then
    raise exception 'payment account not found' using errcode = 'P0002';
  end if;
  perform billing.assert_branch(p_tenant_id, v_row.branch_id);
  perform billing.lock_account_slot(p_tenant_id, v_row.branch_id, v_row.mode);
  update billing.payment_account set is_default = false, is_active = false, is_deleted = true where id = p_id;
  perform billing.ensure_account_default(p_tenant_id, v_row.branch_id, v_row.mode);
  return jsonb_build_object('id', p_id, 'deleted', true);
end;
$$;

-- Tender stamping. Security definer so the public webhook path (no JWT branch list) still resolves
-- the branch default; every lookup is pinned to NEW.tenant_id.
create or replace function billing.stamp_tender_account()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_branch uuid;
  v_refund_of uuid;
  v_acc billing.payment_account%rowtype;
begin
  if new.mode not in ('bank', 'upi', 'card') then
    if new.payment_account_id is not null then
      raise exception 'only bank, UPI and card tenders take a payment account' using errcode = '22023';
    end if;
    return new;
  end if;
  select a.branch_id, p.refund_of_payment_id into v_branch, v_refund_of
  from billing.payment p join billing.billing_account a on a.id = p.account_id
  where p.id = new.payment_id and p.tenant_id = new.tenant_id;
  if new.payment_account_id is not null then
    select * into v_acc from billing.payment_account where id = new.payment_account_id;
    if v_acc.id is null or v_acc.tenant_id <> new.tenant_id or v_acc.branch_id <> v_branch
       or v_acc.mode <> new.mode or not v_acc.is_active or v_acc.is_deleted then
      raise exception 'payment account is not an active % account of this branch', new.mode using errcode = '22023';
    end if;
    return new;
  end if;
  if v_refund_of is not null then
    -- A refund leaves from the account that received the money, even if it is now inactive.
    select t.payment_account_id into new.payment_account_id
    from billing.payment_tender t
    where t.payment_id = v_refund_of and t.mode = new.mode and not t.is_deleted and t.payment_account_id is not null
    order by t.amount_paise desc limit 1;
    if new.payment_account_id is not null then
      return new;
    end if;
  end if;
  select id into new.payment_account_id from billing.payment_account
  where tenant_id = new.tenant_id and branch_id = v_branch and mode = new.mode and is_default and not is_deleted;
  return new;
end;
$$;
revoke all on function billing.stamp_tender_account() from public, anon, authenticated;

create trigger payment_tender_stamp_account before insert on billing.payment_tender
  for each row execute function billing.stamp_tender_account();

-- UPI payee for a branch QR/receipt. Null when the branch has no active default VPA.
create or replace function billing.branch_upi_payee(p_tenant_id uuid, p_branch_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('vpa', p.vpa, 'payeeName', coalesce(p.payee_name, p.label), 'accountId', p.id)
  from billing.payment_account p
  where p.tenant_id = p_tenant_id and p.branch_id = p_branch_id and p.mode = 'upi'
    and p.is_default and not p.is_deleted;
$$;
revoke all on function billing.branch_upi_payee(uuid, uuid) from public, anon, authenticated;
grant execute on function billing.branch_upi_payee(uuid, uuid) to hms_svc_billing, service_role;

create or replace function billing.bill_upi_payee(p_tenant_id uuid, p_bill_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_branch uuid;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.collect');
  select a.branch_id into v_branch from billing.bill b join billing.billing_account a on a.id = b.account_id
  where b.id = p_bill_id and b.tenant_id = p_tenant_id and not b.is_deleted;
  if v_branch is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  return billing.branch_upi_payee(p_tenant_id, v_branch);
end;
$$;

-- Receipt now names the receiving account per tender.
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
    'approvalId', v_pay.approval_id, 'tenders', v_tenders, 'allocations', v_alloc);
end;
$$;

-- Shared grouping for day-end and the CA register. Refunds count negative.
create or replace function billing.account_totals(p_tenant_id uuid, p_branch_id uuid, p_from date, p_to date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'branchId', x.branch_id, 'mode', x.mode, 'paymentAccountId', x.account_id,
    'label', coalesce(x.label, case when x.mode in ('cash', 'credit') then initcap(x.mode) else 'Unassigned' end),
    'maskedAccount', x.masked, 'vpa', x.vpa, 'mid', x.mid, 'tid', x.tid,
    'isActive', x.is_active, 'receivedPaise', x.received, 'refundedPaise', x.refunded,
    'netPaise', x.received - x.refunded, 'count', x.n
  ) order by x.branch_id, x.mode, x.label nulls last), '[]'::jsonb)
  from (
    select a.branch_id, t.mode, t.payment_account_id as account_id, pa.label,
           case when pa.account_last4 is not null then 'XXXX' || pa.account_last4 end as masked,
           pa.vpa, pa.mid, pa.tid, (pa.is_active and not pa.is_deleted) as is_active,
           sum(t.amount_paise) filter (where p.kind <> 'refund') as received,
           coalesce(sum(t.amount_paise) filter (where p.kind = 'refund'), 0) as refunded,
           count(*) as n
    from billing.payment p
    join billing.billing_account a on a.id = p.account_id and a.tenant_id = p.tenant_id
    join billing.payment_tender t on t.payment_id = p.id and not t.is_deleted
    left join billing.payment_account pa on pa.id = t.payment_account_id
    where p.tenant_id = p_tenant_id and not p.is_deleted
      and (p_branch_id is null or a.branch_id = p_branch_id)
      and identity.branch_local_date_v1(a.branch_id, p.received_at) between p_from and p_to
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9
  ) x;
$$;
revoke all on function billing.account_totals(uuid, uuid, date, date) from public, anon, authenticated;

create or replace function billing.day_end_accounts(p_tenant_id uuid, p_branch_id uuid, p_on date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform billing.assert_permission(p_tenant_id, 'billing.view');
  perform billing.assert_branch(p_tenant_id, p_branch_id);
  return jsonb_build_object('branchId', p_branch_id, 'date', p_on,
    'accounts', billing.account_totals(p_tenant_id, p_branch_id, p_on, p_on));
end;
$$;

-- CA register by account. Security definer like earnings_report: a tenant-wide reader sees all branches.
create or replace function billing.account_register(p_tenant_id uuid, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())
     or not identity.has_tenant_permission(p_tenant_id, 'billing.earnings') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or (p_to - p_from) > 399 then
    raise exception 'date range must be 1 to 400 days' using errcode = '22023';
  end if;
  return jsonb_build_object('from', p_from, 'to', p_to, 'branchId', p_branch_id,
    'accounts', billing.account_totals(p_tenant_id, p_branch_id, p_from, p_to));
end;
$$;

do $$
declare
  f text;
begin
  foreach f in array array[
    'billing.payment_account_json(billing.payment_account)', 'billing.lock_account_slot(uuid,uuid,text)',
    'billing.ensure_account_default(uuid,uuid,text)', 'billing.payment_accounts(uuid,uuid)',
    'billing.add_payment_account(uuid,uuid,jsonb)', 'billing.update_payment_account(uuid,uuid,jsonb)',
    'billing.delete_payment_account(uuid,uuid)', 'billing.bill_upi_payee(uuid,uuid)',
    'billing.day_end_accounts(uuid,uuid,date)', 'billing.account_register(uuid,date,date,uuid)',
    'billing.account_totals(uuid,uuid,date,date)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to hms_svc_billing, service_role', f);
  end loop;
end
$$;
