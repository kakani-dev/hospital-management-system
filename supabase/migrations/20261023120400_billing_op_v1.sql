-- cross-schema: approved (billing calls identity.current_tenant_ids, identity.current_branch_ids,
-- identity.has_tenant_permission, identity.branch_exists_v1, identity.branch_local_date_v1,
-- identity.caller_roles_v1, patient.patient_exists_v1, appointment.appointment_billing_ref_v1,
-- and messaging.enqueue from a definer trigger. No table reads outside billing.)
-- OP billing v1. Money is bigint paise. Totals, balances and advance balances are views.
-- The only copied data is bill_line.unit_price_paise and tax_rate_bp.
set local lock_timeout = '5s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

create schema if not exists billing;
revoke all on schema billing from public;
grant usage on schema billing to hms_svc_billing, anon;
comment on schema billing is
  'OP billing owned by hms_svc_billing. IP, pharmacy stock, family wallet, cost estimates and NHCX are hooks only.';

-- --------------------------------------------------------------------- catalog ----
create table billing.tax_code (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null,
  code            text not null,
  sac_hsn_code    text not null,
  is_exempt       boolean not null default false,
  rate_bp         integer not null,
  effective_from  date not null,
  effective_to    date,
  active_range    daterange generated always as (daterange(effective_from, effective_to, '[)')) stored,
  created_on      timestamptz not null default now(),
  created_by      uuid not null,
  updated_on      timestamptz not null default now(),
  updated_by      uuid not null,
  is_deleted      boolean not null default false,
  constraint tax_code_rate check (rate_bp between 0 and 10000),
  constraint tax_code_dates check (effective_to is null or effective_to > effective_from),
  constraint tax_code_len check (length(btrim(code)) between 1 and 40 and length(btrim(sac_hsn_code)) between 1 and 16),
  constraint tax_code_no_overlap exclude using gist (tenant_id with =, code with =, active_range with &&) where (not is_deleted)
);
comment on table billing.tax_code is
  'SAC 9993 healthcare services are exempt (Entry 74). Pharmacy and consumables use a taxable code and a later document series.';

create table billing.service_item (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null,
  code             text not null,
  name             text not null,
  category         text not null,
  tax_code_id      uuid not null references billing.tax_code (id),
  is_stock_tracked boolean not null default false,
  is_active        boolean not null default true,
  created_on       timestamptz not null default now(),
  created_by       uuid not null,
  updated_on       timestamptz not null default now(),
  updated_by       uuid not null,
  is_deleted       boolean not null default false,
  constraint service_item_code_key unique (tenant_id, code),
  constraint service_item_category check (category in (
    'consultation', 'procedure', 'lab', 'imaging', 'consumable', 'room', 'package', 'other')),
  constraint service_item_len check (length(btrim(code)) between 1 and 40 and length(btrim(name)) between 1 and 160)
);
comment on column billing.service_item.is_stock_tracked is
  'Hook only. v1 does not post a stock ledger; bill_line.stock_ledger_ref and billing.bill_line_finalized.v1 are the join.';

create table billing.price_list (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null,
  branch_id         uuid,
  name              text not null,
  is_public_display boolean not null default false,
  scheme_code       text,
  is_active         boolean not null default true,
  created_on        timestamptz not null default now(),
  created_by        uuid not null,
  updated_on        timestamptz not null default now(),
  updated_by        uuid not null,
  is_deleted        boolean not null default false,
  constraint price_list_name_key unique nulls not distinct (tenant_id, branch_id, name),
  constraint price_list_name_len check (length(btrim(name)) between 1 and 120)
);
comment on table billing.price_list is
  'branch_id null is the tenant list. Precedence at lookup is practitioner, then branch, then tenant.';

create table billing.price_list_item (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null,
  price_list_id    uuid not null references billing.price_list (id),
  service_item_id  uuid not null references billing.service_item (id),
  practitioner_id  uuid,
  unit_price_paise bigint not null,
  effective_from   date not null,
  effective_to     date,
  practitioner_key uuid generated always as (coalesce(practitioner_id, '00000000-0000-0000-0000-000000000000'::uuid)) stored,
  active_range     daterange generated always as (daterange(effective_from, effective_to, '[)')) stored,
  created_on       timestamptz not null default now(),
  created_by       uuid not null,
  updated_on       timestamptz not null default now(),
  updated_by       uuid not null,
  is_deleted       boolean not null default false,
  constraint price_list_item_nonneg check (unit_price_paise >= 0),
  constraint price_list_item_dates check (effective_to is null or effective_to > effective_from),
  constraint price_list_item_no_overlap exclude using gist (
    price_list_id with =,
    service_item_id with =,
    practitioner_key with =,
    active_range with &&
  ) where (not is_deleted)
);
comment on table billing.price_list_item is
  'Append-only. A new effective row replaces history; rows are never updated. practitioner_key uses the nil uuid for any practitioner.';

create index price_list_item_lookup_idx
  on billing.price_list_item (tenant_id, service_item_id, effective_from desc)
  where not is_deleted;
create index price_list_branch_idx
  on billing.price_list (tenant_id, branch_id)
  where is_active and not is_deleted;

-- --------------------------------------------------------------------- accounts ----
create table billing.billing_account (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null,
  patient_id      uuid not null,
  branch_id       uuid not null,
  account_type    text not null,
  source_ref_type text not null,
  source_ref_id   uuid,
  status          text not null default 'open',
  created_on      timestamptz not null default now(),
  created_by      uuid not null,
  updated_on      timestamptz not null default now(),
  updated_by      uuid not null,
  is_deleted      boolean not null default false,
  constraint billing_account_type check (account_type in ('op_visit', 'ip_admission', 'walk_in')),
  constraint billing_account_source check (source_ref_type in ('appointment', 'admission', 'none')),
  constraint billing_account_status check (status in ('open', 'closed')),
  constraint billing_account_source_key unique (tenant_id, source_ref_type, source_ref_id)
);
create index billing_account_patient_idx on billing.billing_account (tenant_id, patient_id) where not is_deleted;

create table billing.bill (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null,
  account_id      uuid not null references billing.billing_account (id),
  bill_kind       text not null,
  reverses_bill_id uuid references billing.bill (id),
  bill_no         text,
  status          text not null default 'draft',
  payer_type      text not null default 'self',
  finalized_at    timestamptz,
  finalized_by    uuid,
  created_on      timestamptz not null default now(),
  created_by      uuid not null,
  updated_on      timestamptz not null default now(),
  updated_by      uuid not null,
  is_deleted      boolean not null default false,
  constraint bill_kind check (bill_kind in ('final', 'interim', 'credit_note')),
  constraint bill_status check (status in ('draft', 'finalized', 'cancelled_draft')),
  constraint bill_payer check (payer_type in ('self', 'corporate', 'insurer')),
  constraint bill_credit_note check ((bill_kind = 'credit_note') = (reverses_bill_id is not null)),
  constraint bill_final_shape check (
    status <> 'finalized' or (bill_no is not null and finalized_at is not null and finalized_by is not null)),
  constraint bill_no_len check (bill_no is null or length(bill_no) between 1 and 16)
);
create unique index bill_no_key on billing.bill (tenant_id, bill_no) where bill_no is not null;
create index bill_account_idx on billing.bill (tenant_id, account_id) where not is_deleted;
create index bill_reverses_idx on billing.bill (reverses_bill_id) where reverses_bill_id is not null;

create table billing.bill_line (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null,
  bill_id             uuid not null references billing.bill (id),
  line_no             integer not null,
  service_item_id     uuid not null references billing.service_item (id),
  price_list_item_id  uuid not null references billing.price_list_item (id),
  practitioner_id     uuid,
  quantity            numeric(10,3) not null,
  unit_price_paise    bigint not null,
  tax_rate_bp         integer not null,
  reverses_line_id    uuid references billing.bill_line (id),
  stock_ledger_ref    uuid,
  created_on          timestamptz not null default now(),
  created_by          uuid not null,
  updated_on          timestamptz not null default now(),
  updated_by          uuid not null,
  is_deleted          boolean not null default false,
  constraint bill_line_no_key unique (bill_id, line_no),
  constraint bill_line_qty check (quantity <> 0),
  constraint bill_line_price check (unit_price_paise >= 0),
  constraint bill_line_tax check (tax_rate_bp between 0 and 10000)
);
create index bill_line_bill_idx on billing.bill_line (bill_id) where not is_deleted;
comment on column billing.bill_line.unit_price_paise is 'Price snapshot. The only value copied from the tariff.';
comment on column billing.bill_line.stock_ledger_ref is 'Hook for a future inventory ledger entry. v1 leaves it null.';

create table billing.approval_policy (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null,
  action            text not null,
  role              text not null,
  max_amount_paise  bigint,
  max_percent_bp    integer,
  created_on        timestamptz not null default now(),
  created_by        uuid not null,
  updated_on        timestamptz not null default now(),
  updated_by        uuid not null,
  is_deleted        boolean not null default false,
  constraint approval_policy_key unique (tenant_id, action, role),
  constraint approval_policy_action check (action in ('discount', 'refund', 'write_off', 'cancel_receipt', 'cash_variance')),
  constraint approval_policy_amount check (max_amount_paise is null or max_amount_paise >= 0),
  constraint approval_policy_percent check (max_percent_bp is null or max_percent_bp between 0 and 10000)
);
comment on table billing.approval_policy is
  'Null amount and percent means unlimited. Cashier defaults are ₹200 or 5 percent. Supervisor is ₹2,000 or 20 percent. Manager is unlimited. Refunds are 0 for cashier roles.';

create table billing.approval_request (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null,
  action        text not null,
  subject_type  text not null,
  subject_id    uuid not null,
  amount_paise  bigint not null,
  percent_bp    integer,
  requested_by  uuid not null,
  approver_id   uuid,
  status        text not null default 'pending',
  decided_at    timestamptz,
  note          text,
  payload       jsonb,
  created_on    timestamptz not null default now(),
  created_by    uuid not null,
  updated_on    timestamptz not null default now(),
  updated_by    uuid not null,
  is_deleted    boolean not null default false,
  constraint approval_request_action check (action in ('discount', 'refund', 'write_off', 'cancel_receipt', 'cash_variance')),
  constraint approval_request_status check (status in ('pending', 'approved', 'rejected')),
  constraint approval_request_amount check (amount_paise > 0),
  constraint approval_request_decision check (
    (status = 'pending' and approver_id is null and decided_at is null)
    or (status in ('approved', 'rejected') and approver_id is not null and decided_at is not null))
);
create index approval_request_pending_idx
  on billing.approval_request (tenant_id, status, created_on)
  where status = 'pending' and not is_deleted;

create table billing.discount (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  bill_id      uuid not null references billing.bill (id),
  bill_line_id uuid references billing.bill_line (id),
  kind         text not null,
  value        bigint not null,
  reason_code  text not null,
  approval_id  uuid not null references billing.approval_request (id),
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  constraint discount_kind check (kind in ('percent_bp', 'flat_paise')),
  constraint discount_value check (value > 0),
  constraint discount_reason check (length(btrim(reason_code)) between 1 and 40)
);

-- --------------------------------------------------------------------- money movement ----
create table billing.counter (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null,
  branch_id  uuid not null,
  name       text not null,
  created_on timestamptz not null default now(),
  created_by uuid not null,
  updated_on timestamptz not null default now(),
  updated_by uuid not null,
  is_deleted boolean not null default false,
  constraint counter_name_key unique (tenant_id, branch_id, name),
  constraint counter_name_len check (length(btrim(name)) between 1 and 80)
);

create table billing.counter_session (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null,
  counter_id           uuid not null references billing.counter (id),
  cashier_id           uuid not null,
  business_date        date not null,
  opening_float_paise  bigint not null,
  status               text not null default 'open',
  opened_at            timestamptz not null default now(),
  closed_at            timestamptz,
  created_on           timestamptz not null default now(),
  created_by           uuid not null,
  updated_on           timestamptz not null default now(),
  updated_by           uuid not null,
  is_deleted           boolean not null default false,
  constraint counter_session_status check (status in ('open', 'closed', 'reconciled')),
  constraint counter_session_float check (opening_float_paise >= 0)
);
create unique index counter_session_one_open
  on billing.counter_session (counter_id) where status = 'open' and not is_deleted;
create index counter_session_date_idx on billing.counter_session (tenant_id, business_date);

create table billing.wallet (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null,
  holder_patient_id uuid not null,
  created_on        timestamptz not null default now(),
  created_by        uuid not null,
  updated_on        timestamptz not null default now(),
  updated_by        uuid not null,
  is_deleted        boolean not null default false
);
comment on table billing.wallet is 'Hook only (family wallet, v1.1). No API writes a balance.';

create table billing.wallet_member (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null,
  wallet_id  uuid not null references billing.wallet (id),
  patient_id uuid not null,
  created_on timestamptz not null default now(),
  created_by uuid not null,
  updated_on timestamptz not null default now(),
  updated_by uuid not null,
  is_deleted boolean not null default false,
  constraint wallet_member_key unique (tenant_id, patient_id)
);

create table billing.payment (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null,
  account_id           uuid not null references billing.billing_account (id),
  receipt_no           text not null,
  idempotency_key      uuid not null,
  kind                 text not null,
  amount_paise         bigint not null,
  counter_session_id   uuid references billing.counter_session (id),
  refund_of_payment_id uuid references billing.payment (id),
  approval_id          uuid references billing.approval_request (id),
  wallet_id            uuid references billing.wallet (id),
  received_at          timestamptz not null default now(),
  created_on           timestamptz not null default now(),
  created_by           uuid not null,
  updated_on           timestamptz not null default now(),
  updated_by           uuid not null,
  is_deleted           boolean not null default false,
  constraint payment_kind check (kind in ('payment', 'advance', 'refund')),
  constraint payment_amount check (amount_paise > 0),
  constraint payment_receipt_len check (length(receipt_no) between 1 and 16),
  constraint payment_idem_key unique (tenant_id, idempotency_key),
  constraint payment_receipt_key unique (tenant_id, receipt_no),
  constraint payment_refund_shape check ((kind = 'refund') = (refund_of_payment_id is not null)),
  constraint payment_refund_approval check (kind <> 'refund' or approval_id is not null)
);
create index payment_account_idx on billing.payment (tenant_id, account_id) where not is_deleted;
create index payment_refund_idx on billing.payment (refund_of_payment_id) where refund_of_payment_id is not null;
comment on column billing.payment.wallet_id is 'Hook only. v1 advances are tenant-wide per patient and leave wallet_id null.';

create table billing.payment_tender (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  payment_id   uuid not null references billing.payment (id),
  mode         text not null,
  amount_paise bigint not null,
  reference    text,
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  constraint payment_tender_mode check (mode in ('cash', 'card', 'upi', 'bank', 'credit')),
  constraint payment_tender_amount check (amount_paise > 0)
);
create index payment_tender_payment_idx on billing.payment_tender (payment_id) where not is_deleted;
create index payment_tender_cash_idx on billing.payment_tender (tenant_id, mode) where mode = 'cash' and not is_deleted;

create table billing.allocation (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  payment_id   uuid not null references billing.payment (id),
  bill_id      uuid not null references billing.bill (id),
  amount_paise bigint not null,
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  constraint allocation_amount check (amount_paise <> 0)
);
create index allocation_payment_idx on billing.allocation (payment_id) where not is_deleted;
create index allocation_bill_idx on billing.allocation (bill_id) where not is_deleted;

create table billing.counter_close (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null,
  counter_session_id    uuid not null references billing.counter_session (id),
  mode                  text not null,
  counted_paise         bigint not null,
  variance_approval_id  uuid references billing.approval_request (id),
  closed_by             uuid not null,
  created_on            timestamptz not null default now(),
  created_by            uuid not null,
  updated_on            timestamptz not null default now(),
  updated_by            uuid not null,
  is_deleted            boolean not null default false,
  constraint counter_close_key unique (counter_session_id, mode),
  constraint counter_close_mode check (mode in ('cash', 'card', 'upi', 'bank', 'credit')),
  constraint counter_close_counted check (counted_paise >= 0)
);

create table billing.bill_number_series (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  branch_id    uuid not null,
  doc_type     text not null,
  fiscal_year  text not null,
  prefix       text not null,
  next_value   bigint not null,
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  constraint bill_number_series_key unique (tenant_id, branch_id, doc_type, fiscal_year),
  constraint bill_number_series_doc check (doc_type in ('bill', 'credit_note', 'receipt')),
  constraint bill_number_series_prefix check (prefix ~ '^[A-Z0-9]{1,4}$'),
  constraint bill_number_series_next check (next_value >= 1)
);
comment on table billing.bill_number_series is
  'Gapless per branch, document type and Indian fiscal year. The printed number is at most 16 characters (CGST Rule 46).';

create table billing.branch_profile (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null,
  branch_id  uuid not null,
  doc_prefix text not null,
  created_on timestamptz not null default now(),
  created_by uuid not null,
  updated_on timestamptz not null default now(),
  updated_by uuid not null,
  is_deleted boolean not null default false,
  constraint branch_profile_key unique (tenant_id, branch_id),
  constraint branch_profile_prefix check (doc_prefix ~ '^[A-Z0-9]{1,4}$')
);

create table billing.inbox (
  id           uuid primary key default gen_random_uuid(),
  event_id     uuid not null,
  tenant_id    uuid not null,
  event_type   text not null,
  processed_at timestamptz not null default now(),
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  constraint inbox_event_key unique (event_id)
);

create table billing.payment_link (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null,
  bill_id           uuid not null references billing.bill (id),
  channel           text not null,
  provider_order_id text not null,
  status            text not null default 'created',
  expires_at        timestamptz not null,
  created_on        timestamptz not null default now(),
  created_by        uuid not null,
  updated_on        timestamptz not null default now(),
  updated_by        uuid not null,
  is_deleted        boolean not null default false,
  constraint payment_link_channel check (channel in ('whatsapp', 'sms', 'qr', 'link')),
  constraint payment_link_status check (status in ('created', 'paid', 'expired')),
  constraint payment_link_order_key unique (provider_order_id)
);
comment on table billing.payment_link is
  'Shareable bill link. The amount is not stored; the webhook checks it against the bill due.';

create table billing.provider_webhook_event (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  provider    text not null,
  event_id    text not null,
  received_at timestamptz not null default now(),
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  constraint provider_webhook_event_key unique (provider, event_id)
);

create table billing.cost_estimate (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null,
  patient_id uuid not null,
  branch_id  uuid not null,
  valid_until date not null,
  status     text not null default 'open',
  created_on timestamptz not null default now(),
  created_by uuid not null,
  updated_on timestamptz not null default now(),
  updated_by uuid not null,
  is_deleted boolean not null default false,
  constraint cost_estimate_status check (status in ('open', 'converted', 'expired'))
);
comment on table billing.cost_estimate is
  'Hook only (NABH PRE.6, v1.1). No price is stored; a later API resolves the effective tariff.';

create table billing.cost_estimate_line (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null,
  estimate_id        uuid not null references billing.cost_estimate (id),
  service_item_id    uuid not null,
  price_list_item_id uuid not null,
  quantity           numeric(10,3) not null,
  created_on         timestamptz not null default now(),
  created_by         uuid not null,
  updated_on         timestamptz not null default now(),
  updated_by         uuid not null,
  is_deleted         boolean not null default false,
  constraint cost_estimate_line_qty check (quantity > 0)
);

create table billing.charge_suggestion (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null,
  bill_id        uuid not null references billing.bill (id),
  service_item_id uuid not null,
  source_ref_id  uuid not null,
  confidence_bp  integer not null,
  status         text not null default 'pending',
  decided_by     uuid,
  created_on     timestamptz not null default now(),
  created_by     uuid not null,
  updated_on     timestamptz not null default now(),
  updated_by     uuid not null,
  is_deleted     boolean not null default false,
  constraint charge_suggestion_confidence check (confidence_bp between 0 and 10000),
  constraint charge_suggestion_status check (status in ('pending', 'accepted', 'rejected'))
);
comment on table billing.charge_suggestion is
  'Hook only. v1 does not suggest charges. An accepted row would be the only path to a bill line.';

-- --------------------------------------------------------------------- triggers ----
create or replace function billing.reject_finalized_change()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_bill uuid;
  v_status text;
begin
  if tg_table_name = 'bill' then
    if tg_op = 'DELETE' or (tg_op = 'UPDATE' and old.status = 'finalized') then
      raise exception 'finalized bills are immutable; issue a credit note' using errcode = '55000';
    end if;
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  v_bill := case when tg_op = 'DELETE' then old.bill_id else new.bill_id end;
  select b.status into v_status from billing.bill b where b.id = v_bill;
  if v_status = 'finalized' then
    raise exception 'finalized bills are immutable; issue a credit note' using errcode = '55000';
  end if;
  if tg_op = 'UPDATE' and old.bill_id is distinct from new.bill_id then
    select b.status into v_status from billing.bill b where b.id = old.bill_id;
    if v_status = 'finalized' then
      raise exception 'finalized bills are immutable; issue a credit note' using errcode = '55000';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger bill_immutable before update or delete on billing.bill
  for each row execute function billing.reject_finalized_change();
create trigger bill_line_immutable before insert or update or delete on billing.bill_line
  for each row execute function billing.reject_finalized_change();
create trigger discount_immutable before insert or update or delete on billing.discount
  for each row execute function billing.reject_finalized_change();

create or replace function billing.reject_credit_sign()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_kind text;
begin
  select bill_kind into v_kind from billing.bill where id = new.bill_id;
  if v_kind = 'credit_note' and new.quantity > 0 then
    raise exception 'credit note lines are negative' using errcode = '23514';
  end if;
  if v_kind is distinct from 'credit_note' and new.quantity < 0 then
    raise exception 'negative quantity is only valid on a credit note' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger bill_line_sign before insert or update of quantity, bill_id on billing.bill_line
  for each row execute function billing.reject_credit_sign();

create or replace function billing.reject_closed_session_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' or old.status = 'reconciled' then
    raise exception 'a closed counter session cannot be changed' using errcode = '55000';
  end if;
  if old.status = 'closed' and (
       new.status is distinct from 'reconciled'
       or new.counter_id is distinct from old.counter_id
       or new.cashier_id is distinct from old.cashier_id
       or new.business_date is distinct from old.business_date
       or new.opening_float_paise is distinct from old.opening_float_paise
       or new.opened_at is distinct from old.opened_at) then
    raise exception 'a closed counter session cannot be changed' using errcode = '55000';
  end if;
  return new;
end;
$$;

create trigger counter_session_immutable before update or delete on billing.counter_session
  for each row execute function billing.reject_closed_session_change();

create or replace function billing.assert_tender_sum()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment uuid := coalesce(new.payment_id, old.payment_id);
  v_amount bigint;
  v_sum bigint;
begin
  select amount_paise into v_amount from billing.payment where id = v_payment;
  select coalesce(sum(amount_paise), 0) into v_sum
    from billing.payment_tender where payment_id = v_payment and not is_deleted;
  if v_sum is distinct from v_amount then
    raise exception 'tender amounts must add up to the payment' using errcode = '23514';
  end if;
  return null;
end;
$$;

create constraint trigger payment_tender_sum
  after insert or update or delete on billing.payment_tender
  deferrable initially deferred
  for each row execute function billing.assert_tender_sum();

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
  v_bill uuid;
  v_status text;
  v_kind text;
  v_account uuid;
  v_pay_account uuid;
begin
  select amount_paise, account_id into v_amount, v_pay_account from billing.payment where id = v_payment;
  select coalesce(sum(amount_paise), 0) into v_sum
    from billing.allocation where payment_id = v_payment and not is_deleted;
  if v_sum > v_amount or v_sum < 0 then
    raise exception 'allocations exceed the payment' using errcode = '23514';
  end if;
  if tg_op <> 'DELETE' then
    select status, bill_kind, account_id into v_status, v_kind, v_account from billing.bill where id = new.bill_id;
    if v_status is distinct from 'finalized' or v_kind = 'credit_note' or v_account is distinct from v_pay_account then
      raise exception 'allocations apply to a finalized bill on the same account' using errcode = '55000';
    end if;
  end if;
  return null;
end;
$$;

create constraint trigger allocation_bound
  after insert or update or delete on billing.allocation
  deferrable initially deferred
  for each row execute function billing.assert_allocation_bound();

create or replace function billing.emit_billing_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_line record;
  v_total bigint;
begin
  if tg_table_name = 'bill' then
    if tg_op <> 'UPDATE' or new.status is distinct from 'finalized' or old.status = 'finalized' then
      return null;
    end if;
    select t.total_paise into v_total from billing.bill_totals_v1 t where t.bill_id = new.id;
    perform messaging.enqueue(new.tenant_id, 'billing', new.id,
      case when new.bill_kind = 'credit_note' then 'billing.credit_note_finalized.v1' else 'billing.bill_finalized.v1' end,
      jsonb_build_object('bill_id', new.id, 'tenant_id', new.tenant_id, 'account_id', new.account_id,
        'bill_no', new.bill_no, 'bill_kind', new.bill_kind, 'total_paise', coalesce(v_total, 0)));
    for v_line in
      select id, service_item_id, quantity, unit_price_paise, tax_rate_bp, stock_ledger_ref
      from billing.bill_line where bill_id = new.id and not is_deleted
    loop
      perform messaging.enqueue(new.tenant_id, 'billing', v_line.id, 'billing.bill_line_finalized.v1',
        jsonb_build_object('bill_line_id', v_line.id, 'bill_id', new.id, 'tenant_id', new.tenant_id,
          'service_item_id', v_line.service_item_id, 'quantity', v_line.quantity,
          'unit_price_paise', v_line.unit_price_paise, 'tax_rate_bp', v_line.tax_rate_bp,
          'stock_ledger_ref', v_line.stock_ledger_ref));
    end loop;
    return null;
  end if;
  if tg_table_name = 'payment' and tg_op = 'INSERT' then
    perform messaging.enqueue(new.tenant_id, 'billing', new.id,
      case new.kind
        when 'refund' then 'billing.refund_issued.v1'
        when 'advance' then 'billing.advance_received.v1'
        else 'billing.payment_received.v1' end,
      jsonb_build_object('payment_id', new.id, 'tenant_id', new.tenant_id, 'account_id', new.account_id,
        'receipt_no', new.receipt_no, 'kind', new.kind, 'amount_paise', new.amount_paise,
        'refund_of_payment_id', new.refund_of_payment_id));
    return null;
  end if;
  if tg_table_name = 'approval_request' and tg_op = 'UPDATE'
     and old.status = 'pending' and new.status is distinct from 'pending' then
    perform messaging.enqueue(new.tenant_id, 'billing', new.id, 'billing.approval_decided.v1',
      jsonb_build_object('approval_id', new.id, 'tenant_id', new.tenant_id, 'action', new.action,
        'status', new.status, 'amount_paise', new.amount_paise, 'approver_id', new.approver_id));
    return null;
  end if;
  if tg_table_name = 'counter_session' and tg_op = 'UPDATE'
     and new.status = 'closed' and old.status is distinct from 'closed' then
    perform messaging.enqueue(new.tenant_id, 'billing', new.id, 'billing.counter_session_closed.v1',
      jsonb_build_object('counter_session_id', new.id, 'tenant_id', new.tenant_id,
        'counter_id', new.counter_id, 'business_date', new.business_date));
  end if;
  return null;
end;
$$;
revoke all on function billing.emit_billing_event() from public, anon, authenticated;

create trigger bill_outbox after update on billing.bill
  for each row execute function billing.emit_billing_event();
create trigger payment_outbox after insert on billing.payment
  for each row execute function billing.emit_billing_event();
create trigger approval_outbox after update on billing.approval_request
  for each row execute function billing.emit_billing_event();
create trigger counter_session_outbox after update on billing.counter_session
  for each row execute function billing.emit_billing_event();

-- Audit columns, tenant immutability, audit log.
do $$
declare
  t text;
begin
  foreach t in array array[
    'tax_code', 'service_item', 'price_list', 'price_list_item', 'billing_account', 'bill', 'bill_line',
    'approval_policy', 'approval_request', 'discount', 'counter', 'counter_session', 'wallet', 'wallet_member',
    'payment', 'payment_tender', 'allocation', 'counter_close', 'bill_number_series', 'branch_profile',
    'inbox', 'payment_link', 'provider_webhook_event', 'cost_estimate', 'cost_estimate_line', 'charge_suggestion'
  ]
  loop
    execute format('create trigger %I before insert or update on billing.%I for each row execute function audit.stamp_audit_columns()', t || '_audit_columns', t);
    execute format('create trigger %I before update on billing.%I for each row execute function audit.prevent_tenant_change()', t || '_tenant_immutable', t);
    execute format('create trigger %I after insert or update or delete on billing.%I for each row execute function audit.log_row_change()', t || '_audit_log', t);
    execute format('alter table billing.%I enable row level security', t);
    execute format('grant select, insert, update on billing.%I to hms_svc_billing', t);
  end loop;
end
$$;

-- Draft line removal is a soft delete through billing.remove_line (owner), not a hard delete.
revoke delete on all tables in schema billing from hms_svc_billing, anon, authenticated;

-- --------------------------------------------------------------------- RLS ----
do $$
declare
  t text;
begin
  foreach t in array array[
    'tax_code', 'service_item', 'price_list_item', 'approval_policy', 'approval_request',
    'bill_number_series', 'inbox', 'provider_webhook_event', 'wallet', 'wallet_member', 'cost_estimate_line'
  ]
  loop
    execute format(
      'create policy %I on billing.%I for all to hms_svc_billing using (tenant_id in (select identity.current_tenant_ids())) with check (tenant_id in (select identity.current_tenant_ids()))',
      t || '_tenant', t);
  end loop;
end
$$;

create policy price_list_tenant on billing.price_list for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and (branch_id is null or branch_id in (select identity.current_branch_ids(tenant_id))))
  with check (tenant_id in (select identity.current_tenant_ids())
         and (branch_id is null or branch_id in (select identity.current_branch_ids(tenant_id))));

create policy billing_account_branch on billing.billing_account for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and branch_id in (select identity.current_branch_ids(tenant_id)))
  with check (tenant_id in (select identity.current_tenant_ids())
         and branch_id in (select identity.current_branch_ids(tenant_id)));

create policy counter_branch on billing.counter for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and branch_id in (select identity.current_branch_ids(tenant_id)))
  with check (tenant_id in (select identity.current_tenant_ids())
         and branch_id in (select identity.current_branch_ids(tenant_id)));

create policy branch_profile_branch on billing.branch_profile for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and branch_id in (select identity.current_branch_ids(tenant_id)))
  with check (tenant_id in (select identity.current_tenant_ids())
         and branch_id in (select identity.current_branch_ids(tenant_id)));

create policy cost_estimate_branch on billing.cost_estimate for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and branch_id in (select identity.current_branch_ids(tenant_id)))
  with check (tenant_id in (select identity.current_tenant_ids())
         and branch_id in (select identity.current_branch_ids(tenant_id)));

create policy counter_session_branch on billing.counter_session for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.counter c where c.id = counter_id
           and c.branch_id in (select identity.current_branch_ids(counter_session.tenant_id))))
  with check (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.counter c where c.id = counter_id
           and c.branch_id in (select identity.current_branch_ids(counter_session.tenant_id))));

create policy bill_branch on billing.bill for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.billing_account a where a.id = account_id
           and a.branch_id in (select identity.current_branch_ids(bill.tenant_id))))
  with check (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.billing_account a where a.id = account_id
           and a.branch_id in (select identity.current_branch_ids(bill.tenant_id))));

create policy bill_line_branch on billing.bill_line for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.bill b where b.id = bill_id))
  with check (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.bill b where b.id = bill_id));

create policy discount_branch on billing.discount for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.bill b where b.id = bill_id))
  with check (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.bill b where b.id = bill_id));

create policy payment_branch on billing.payment for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.billing_account a where a.id = account_id
           and a.branch_id in (select identity.current_branch_ids(payment.tenant_id))))
  with check (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.billing_account a where a.id = account_id
           and a.branch_id in (select identity.current_branch_ids(payment.tenant_id))));

create policy payment_tender_branch on billing.payment_tender for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.payment p where p.id = payment_id))
  with check (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.payment p where p.id = payment_id));

create policy allocation_branch on billing.allocation for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.payment p where p.id = payment_id))
  with check (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.payment p where p.id = payment_id));

create policy counter_close_branch on billing.counter_close for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.counter_session s where s.id = counter_session_id))
  with check (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.counter_session s where s.id = counter_session_id));

create policy payment_link_branch on billing.payment_link for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.bill b where b.id = bill_id))
  with check (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.bill b where b.id = bill_id));

create policy charge_suggestion_branch on billing.charge_suggestion for all to hms_svc_billing
  using (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.bill b where b.id = bill_id))
  with check (tenant_id in (select identity.current_tenant_ids())
         and exists (select 1 from billing.bill b where b.id = bill_id));
