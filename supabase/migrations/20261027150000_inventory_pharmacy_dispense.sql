-- cross-schema: approved (new schema pharmacy, hosted by the inventory service until a pharmacy service exists; see docs/adr/0004-pharmacy-dispensing-in-inventory.md. Reads clinical.consultations / prescription_lines, appointment.practitioners.display_name and patient.patients name + MRN inside security-definer functions only; RLS helpers identity.current_tenant_ids / current_branch_ids / can_access_branch / has_tenant_permission; audit.* trigger functions; writes inventory.stock_ledger 'dispense' rows (inventory-owned). Adds the pharmacy.view / pharmacy.dispense permission names to identity.role_permissions.)
-- #106 PR1: pharmacist queue of finalized prescriptions, prescription detail, and dispensing with
-- FEFO batch deduction and partial dispensing. Tenant id is never taken from the client: the API
-- passes the server-resolved tenant and every function checks it against the caller's memberships.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create schema if not exists pharmacy;
revoke all on schema pharmacy from public, anon, authenticated;
grant usage on schema pharmacy to hms_svc_inventory, service_role;
comment on schema pharmacy is
  'Dispensing records. Holds no stock: quantities move only through inventory.stock_ledger. Hosted by the inventory service (ADR 0004).';

-- -------------------------------------------------------------- permissions ----
insert into identity.role_permissions (role, permission) values
  ('pharmacist', 'pharmacy.view'),
  ('pharmacist', 'pharmacy.dispense'),
  ('tenant_admin', 'pharmacy.view'),
  ('tenant_admin', 'pharmacy.dispense')
on conflict do nothing;

-- ------------------------------------------------------------------- tables ----
create table pharmacy.dispense (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references identity.tenants (id) on delete restrict,
  branch_id        uuid not null,
  store_id         uuid not null references inventory.store (id) on delete restrict,
  consultation_id  uuid not null,
  patient_id       uuid not null,
  idempotency_key  uuid not null,
  dispensed_by     uuid not null,
  note             text,
  created_on       timestamptz not null default now(),
  created_by       uuid not null,
  updated_on       timestamptz not null default now(),
  updated_by       uuid not null,
  is_deleted       boolean not null default false,
  constraint dispense_tenant_id_id_key unique (tenant_id, id),
  constraint dispense_idem_key unique (tenant_id, idempotency_key),
  constraint dispense_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete restrict,
  constraint dispense_consultation_same_tenant
    foreign key (tenant_id, consultation_id) references clinical.consultations (tenant_id, id) on delete restrict,
  constraint dispense_note_len check (coalesce(length(note), 0) <= 500),
  constraint dispense_never_deleted check (not is_deleted)
);
create index dispense_consultation_idx on pharmacy.dispense (consultation_id, created_on);
comment on table pharmacy.dispense is
  'One dispensing event against a finalized prescription. Append-only; a replayed Idempotency-Key returns the same row.';

create table pharmacy.dispense_line (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null,
  dispense_id           uuid not null,
  prescription_line_id  uuid not null references clinical.prescription_lines (id) on delete restrict,
  item_id               uuid not null references inventory.item (id) on delete restrict,
  batch_id              uuid not null references inventory.batch (id) on delete restrict,
  qty_base              bigint not null,
  completes_line        boolean not null,
  created_on            timestamptz not null default now(),
  created_by            uuid not null,
  updated_on            timestamptz not null default now(),
  updated_by            uuid not null,
  is_deleted            boolean not null default false,
  constraint dispense_line_dispense_same_tenant
    foreign key (tenant_id, dispense_id) references pharmacy.dispense (tenant_id, id) on delete restrict,
  constraint dispense_line_qty check (qty_base > 0),
  constraint dispense_line_never_deleted check (not is_deleted)
);
create index dispense_line_rx_line_idx on pharmacy.dispense_line (prescription_line_id);
comment on table pharmacy.dispense_line is
  'Quantity taken from one batch for one prescription line. Its id is the stock_ledger source_id (source_type pharmacy_dispense). completes_line marks the prescription line as fully dispensed.';

create or replace function pharmacy.reject_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'dispensing records are append-only' using errcode = '55000';
end;
$$;

create trigger dispense_audit_columns before insert on pharmacy.dispense
  for each row execute function audit.stamp_audit_columns();
create trigger dispense_append_only before update or delete on pharmacy.dispense
  for each row execute function pharmacy.reject_change();
create trigger dispense_audit_log after insert on pharmacy.dispense
  for each row execute function audit.log_row_change();
create trigger dispense_line_audit_columns before insert on pharmacy.dispense_line
  for each row execute function audit.stamp_audit_columns();
create trigger dispense_line_append_only before update or delete on pharmacy.dispense_line
  for each row execute function pharmacy.reject_change();
create trigger dispense_line_audit_log after insert on pharmacy.dispense_line
  for each row execute function audit.log_row_change();

-- Fail closed: no table grants. Everything goes through the functions below.
alter table pharmacy.dispense enable row level security;
alter table pharmacy.dispense_line enable row level security;
revoke all on pharmacy.dispense, pharmacy.dispense_line from public, anon, authenticated;

-- ----------------------------------------------------------------- helpers ----
create or replace function pharmacy.assert_permission(p_tenant_id uuid, p_permission text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'prescription not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_permission(p_tenant_id, p_permission) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
end;
$$;

-- A prescription the pharmacy can act on: finalized, not replaced by a finalized correction,
-- with at least one line. Unknown / other tenant -> P0002; other branch -> 42501.
create or replace function pharmacy.load_rx(p_tenant_id uuid, p_id uuid, p_lock boolean default false)
returns clinical.consultations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v clinical.consultations%rowtype;
begin
  if p_lock then
    select * into v from clinical.consultations
    where id = p_id and tenant_id = p_tenant_id and not is_deleted for update;
  else
    select * into v from clinical.consultations
    where id = p_id and tenant_id = p_tenant_id and not is_deleted;
  end if;
  if v.id is null or v.status <> 'finalized' then
    raise exception 'prescription not found' using errcode = 'P0002';
  end if;
  if not identity.can_access_branch(p_tenant_id, v.branch_id) then
    raise exception 'this prescription is at a branch you cannot access' using errcode = '42501';
  end if;
  return v;
end;
$$;

create or replace function pharmacy.is_superseded(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from clinical.consultations n
                 where n.supersedes_id = p_id and n.status = 'finalized' and not n.is_deleted)
$$;

-- pending: nothing dispensed; partial: something dispensed, a line still open; dispensed: every line complete.
create or replace function pharmacy.rx_status(p_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not exists (select 1 from pharmacy.dispense d where d.consultation_id = p_id) then 'pending'
    when exists (
      select 1 from clinical.prescription_lines l
      where l.consultation_id = p_id and not l.is_deleted
        and not exists (select 1 from pharmacy.dispense_line dl
                        where dl.prescription_line_id = l.id and dl.completes_line)) then 'partial'
    else 'dispensed'
  end
$$;

create or replace function pharmacy.rx_json(p_tenant_id uuid, p_id uuid, p_store_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', c.id, 'branchId', c.branch_id, 'patientId', c.patient_id,
    'patientName', p.first_name || ' ' || p.last_name, 'patientMrn', p.mrn,
    'practitionerId', c.practitioner_id, 'doctorName', pr.display_name,
    'finalizedOn', c.finalized_on, 'version', c.version,
    'diagnosisText', c.diagnosis_text,
    'superseded', pharmacy.is_superseded(c.id),
    'status', pharmacy.rx_status(c.id),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'lineNo', l.line_no, 'medicineName', l.medicine_name, 'strength', l.strength,
        'dose', l.dose, 'frequency', l.frequency, 'durationDays', l.duration_days,
        'route', l.route, 'foodTiming', l.food_timing, 'instructions', l.instructions,
        'inventoryItemId', l.inventory_item_id,
        'dispensedBase', coalesce((select sum(dl.qty_base) from pharmacy.dispense_line dl
                                   where dl.prescription_line_id = l.id), 0),
        'complete', exists (select 1 from pharmacy.dispense_line dl
                            where dl.prescription_line_id = l.id and dl.completes_line),
        'availableBase', case when p_store_id is null or l.inventory_item_id is null then null else
          coalesce((select sum(sc.on_hand_base) from inventory.stock_balance_cache sc
                    join inventory.batch b on b.id = sc.batch_id
                    where sc.store_id = p_store_id and sc.tenant_id = p_tenant_id
                      and b.item_id = l.inventory_item_id and b.expiry_date >= current_date
                      and not b.is_deleted), 0) end
      ) order by l.line_no)
      from clinical.prescription_lines l where l.consultation_id = c.id and not l.is_deleted), '[]'::jsonb),
    'dispenses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id, 'storeId', d.store_id, 'dispensedBy', d.dispensed_by, 'createdOn', d.created_on,
        'note', d.note,
        'lines', (select jsonb_agg(jsonb_build_object(
                    'prescriptionLineId', dl.prescription_line_id, 'itemId', dl.item_id,
                    'brandName', i.brand_name, 'batchId', dl.batch_id, 'batchNo', b.batch_no,
                    'expiryDate', b.expiry_date, 'qtyBase', dl.qty_base, 'completesLine', dl.completes_line)
                    order by dl.created_on, b.expiry_date)
                  from pharmacy.dispense_line dl
                  join inventory.batch b on b.id = dl.batch_id
                  join inventory.item i on i.id = dl.item_id
                  where dl.dispense_id = d.id)
      ) order by d.created_on)
      from pharmacy.dispense d where d.consultation_id = c.id), '[]'::jsonb))
  from clinical.consultations c
  join patient.patients p on p.id = c.patient_id and p.tenant_id = c.tenant_id
  join appointment.practitioners pr on pr.id = c.practitioner_id
  where c.id = p_id and c.tenant_id = p_tenant_id
$$;

-- ----------------------------------------------------------------- queries ----
-- Finalized prescriptions at the caller's branches (or one branch), oldest first.
-- p_status: open (pending + partial, the default), all, pending, partial, dispensed.
create or replace function pharmacy.list_queue(p_tenant_id uuid, p_branch_id uuid, p_status text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_status text := coalesce(nullif(btrim(p_status), ''), 'open');
begin
  perform pharmacy.assert_permission(p_tenant_id, 'pharmacy.view');
  if v_status not in ('open', 'all', 'pending', 'partial', 'dispensed') then
    raise exception 'status must be open, all, pending, partial, or dispensed' using errcode = '22023';
  end if;
  if p_branch_id is not null and not identity.can_access_branch(p_tenant_id, p_branch_id) then
    raise exception 'branch out of scope' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(q.row order by q.finalized_on, q.id)
    from (
      select c.id, c.finalized_on, jsonb_build_object(
        'id', c.id, 'branchId', c.branch_id, 'patientId', c.patient_id,
        'patientName', p.first_name || ' ' || p.last_name, 'patientMrn', p.mrn,
        'doctorName', pr.display_name, 'finalizedOn', c.finalized_on,
        'lineCount', (select count(*) from clinical.prescription_lines l
                      where l.consultation_id = c.id and not l.is_deleted),
        'status', s.status) as row
      from clinical.consultations c
      join patient.patients p on p.id = c.patient_id and p.tenant_id = c.tenant_id
      join appointment.practitioners pr on pr.id = c.practitioner_id
      cross join lateral (select pharmacy.rx_status(c.id) as status) s
      where c.tenant_id = p_tenant_id
        and c.status = 'finalized' and not c.is_deleted
        and (p_branch_id is null or c.branch_id = p_branch_id)
        and identity.can_access_branch(p_tenant_id, c.branch_id)
        and not pharmacy.is_superseded(c.id)
        and exists (select 1 from clinical.prescription_lines l where l.consultation_id = c.id and not l.is_deleted)
        and (v_status = 'all'
             or (v_status = 'open' and s.status in ('pending', 'partial'))
             or s.status = v_status)
      order by c.finalized_on, c.id
      limit 200
    ) q), '[]'::jsonb);
end;
$$;

create or replace function pharmacy.get_prescription(p_tenant_id uuid, p_id uuid, p_store_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v clinical.consultations%rowtype;
begin
  perform pharmacy.assert_permission(p_tenant_id, 'pharmacy.view');
  v := pharmacy.load_rx(p_tenant_id, p_id);
  if p_store_id is not null and not exists (
    select 1 from inventory.store s
    where s.id = p_store_id and s.tenant_id = p_tenant_id and s.branch_id = v.branch_id and not s.is_deleted) then
    raise exception 'store not found at this branch' using errcode = 'P0002';
  end if;
  return pharmacy.rx_json(p_tenant_id, p_id, p_store_id);
end;
$$;

-- ---------------------------------------------------------------- dispense ----
-- Body: { consultationId, storeId, note?, lines: [{ lineNo, itemId?, qtyBase, complete? }] }.
-- Each line is taken from non-expired batches in FEFO order (earliest expiry first). complete
-- defaults to true; false records a partial supply and leaves the line open for a later dispense.
create or replace function pharmacy.dispense(p_tenant_id uuid, p_key uuid, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rx clinical.consultations%rowtype;
  v_existing uuid;
  v_store inventory.store%rowtype;
  v_actor uuid;
  v_dispense uuid;
  v_line jsonb;
  v_rx_line clinical.prescription_lines%rowtype;
  v_line_no integer;
  v_item uuid;
  v_qty bigint;
  v_left bigint;
  v_take bigint;
  v_complete boolean;
  v_avail bigint;
  v_batch record;
  v_dl uuid;
  v_cost bigint;
  v_seen integer[] := '{}';
begin
  perform pharmacy.assert_permission(p_tenant_id, 'pharmacy.dispense');
  if p_key is null then
    raise exception 'an idempotency key is required' using errcode = '22023';
  end if;
  select d.consultation_id into v_existing from pharmacy.dispense d
  where d.tenant_id = p_tenant_id and d.idempotency_key = p_key;
  if v_existing is not null then
    perform pharmacy.load_rx(p_tenant_id, v_existing);
    return pharmacy.rx_json(p_tenant_id, v_existing, null);
  end if;
  if p_body is null or jsonb_typeof(p_body) <> 'object' then
    raise exception 'body must be a JSON object' using errcode = '22023';
  end if;
  if coalesce(p_body ->> 'consultationId', '') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' then
    raise exception 'consultationId is required' using errcode = '22023';
  end if;
  if coalesce(p_body ->> 'storeId', '') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' then
    raise exception 'storeId is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_body -> 'lines') is distinct from 'array' or jsonb_array_length(p_body -> 'lines') < 1 then
    raise exception 'at least one line is required' using errcode = '22023';
  end if;
  if jsonb_array_length(p_body -> 'lines') > 50 then
    raise exception 'at most 50 lines' using errcode = '22023';
  end if;
  if length(coalesce(p_body ->> 'note', '')) > 500 then
    raise exception 'note must be at most 500 characters' using errcode = '22023';
  end if;

  -- Row lock on the prescription serialises two pharmacists dispensing the same Rx.
  v_rx := pharmacy.load_rx(p_tenant_id, (p_body ->> 'consultationId')::uuid, true);
  if pharmacy.is_superseded(v_rx.id) then
    raise exception 'this prescription was replaced by a correction; dispense the latest version' using errcode = '55000';
  end if;
  if exists (select 1 from patient.patients p where p.id = v_rx.patient_id and p.deleted_at is not null) then
    raise exception 'the patient record is deleted' using errcode = '55000';
  end if;
  -- A replay that raced past the first lookup while we waited for the lock.
  select d.consultation_id into v_existing from pharmacy.dispense d
  where d.tenant_id = p_tenant_id and d.idempotency_key = p_key;
  if v_existing is not null then
    return pharmacy.rx_json(p_tenant_id, v_existing, null);
  end if;

  select * into v_store from inventory.store s
  where s.id = (p_body ->> 'storeId')::uuid and s.tenant_id = p_tenant_id and not s.is_deleted;
  if v_store.id is null or v_store.branch_id <> v_rx.branch_id then
    raise exception 'store not found at this branch' using errcode = 'P0002';
  end if;
  if v_store.store_kind not in ('op_pharmacy', 'ip_pharmacy') or not v_store.is_active then
    raise exception 'dispense from an active pharmacy store' using errcode = '22023';
  end if;
  if v_store.licence_valid_to is null or v_store.licence_valid_to < current_date then
    raise exception 'the store''s drug licence has expired' using errcode = '55000';
  end if;

  v_actor := audit.session_actor_id();
  if v_actor is null then
    raise exception 'a pharmacist must be signed in' using errcode = '42501';
  end if;
  insert into pharmacy.dispense (tenant_id, branch_id, store_id, consultation_id, patient_id,
                                 idempotency_key, dispensed_by, note)
  values (p_tenant_id, v_rx.branch_id, v_store.id, v_rx.id, v_rx.patient_id, p_key, v_actor,
          nullif(btrim(p_body ->> 'note'), ''))
  returning id into v_dispense;

  for v_line in select value from jsonb_array_elements(p_body -> 'lines') loop
    if jsonb_typeof(v_line -> 'lineNo') is distinct from 'number' or (v_line ->> 'lineNo') !~ '^[0-9]{1,4}$' then
      raise exception 'each line needs a lineNo' using errcode = '22023';
    end if;
    v_line_no := (v_line ->> 'lineNo')::integer;
    if v_line_no = any (v_seen) then
      raise exception 'line % is listed twice', v_line_no using errcode = '22023';
    end if;
    v_seen := v_seen || v_line_no;
    select * into v_rx_line from clinical.prescription_lines l
    where l.consultation_id = v_rx.id and l.line_no = v_line_no and not l.is_deleted;
    if v_rx_line.id is null then
      raise exception 'line % is not on this prescription', v_line_no using errcode = '22023';
    end if;
    if exists (select 1 from pharmacy.dispense_line dl
               where dl.prescription_line_id = v_rx_line.id and dl.completes_line) then
      raise exception 'line % (%) is already dispensed', v_line_no, v_rx_line.medicine_name using errcode = '55000';
    end if;
    if jsonb_typeof(v_line -> 'qtyBase') is distinct from 'number' or (v_line ->> 'qtyBase') !~ '^[0-9]{1,6}$'
       or (v_line ->> 'qtyBase')::bigint < 1 then
      raise exception 'line %: quantity must be a whole number from 1 to 999999', v_line_no using errcode = '22023';
    end if;
    v_qty := (v_line ->> 'qtyBase')::bigint;
    if v_line ? 'complete' and jsonb_typeof(v_line -> 'complete') <> 'boolean' then
      raise exception 'line %: complete must be true or false', v_line_no using errcode = '22023';
    end if;
    v_complete := coalesce((v_line ->> 'complete')::boolean, true);
    if coalesce(v_line ->> 'itemId', '') <> '' then
      if (v_line ->> 'itemId') !~* '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' then
        raise exception 'line %: itemId must be a UUID', v_line_no using errcode = '22023';
      end if;
      v_item := (v_line ->> 'itemId')::uuid;
    else
      v_item := v_rx_line.inventory_item_id;
    end if;
    if v_item is null then
      raise exception 'line %: choose the stock item for %', v_line_no, v_rx_line.medicine_name using errcode = '22023';
    end if;
    if not exists (select 1 from inventory.item i
                   where i.id = v_item and i.tenant_id = p_tenant_id and i.is_active and not i.is_deleted) then
      raise exception 'line %: item not found', v_line_no using errcode = 'P0002';
    end if;

    -- FEFO over non-expired batches; the row locks make the availability check race-free.
    perform 1 from inventory.stock_balance_cache sc
    join inventory.batch b on b.id = sc.batch_id
    where sc.store_id = v_store.id and b.item_id = v_item and sc.on_hand_base > 0
    for update of sc;
    select coalesce(sum(sc.on_hand_base), 0) into v_avail
    from inventory.stock_balance_cache sc
    join inventory.batch b on b.id = sc.batch_id
    where sc.store_id = v_store.id and sc.tenant_id = p_tenant_id and b.item_id = v_item
      and sc.on_hand_base > 0 and b.expiry_date >= current_date and not b.is_deleted;
    if v_avail < v_qty then
      raise exception 'line %: only % in stock (unexpired) for %; dispense less and mark it partial',
        v_line_no, v_avail, v_rx_line.medicine_name using errcode = '55000';
    end if;

    v_left := v_qty;
    for v_batch in
      select sc.batch_id, sc.on_hand_base
      from inventory.stock_balance_cache sc
      join inventory.batch b on b.id = sc.batch_id
      where sc.store_id = v_store.id and sc.tenant_id = p_tenant_id and b.item_id = v_item
        and sc.on_hand_base > 0 and b.expiry_date >= current_date and not b.is_deleted
      order by b.expiry_date, b.created_on, b.id
    loop
      exit when v_left <= 0;
      v_take := least(v_left, v_batch.on_hand_base);
      v_left := v_left - v_take;
      select l.unit_cost_paise into v_cost from inventory.stock_ledger l
      where l.store_id = v_store.id and l.batch_id = v_batch.batch_id and l.qty_delta_base > 0
      order by l.seq desc limit 1;
      insert into pharmacy.dispense_line (tenant_id, dispense_id, prescription_line_id, item_id, batch_id,
                                          qty_base, completes_line)
      values (p_tenant_id, v_dispense, v_rx_line.id, v_item, v_batch.batch_id, v_take, v_complete)
      returning id into v_dl;
      insert into inventory.stock_ledger (tenant_id, store_id, batch_id, qty_delta_base, movement,
                                          unit_cost_paise, source_type, source_id)
      values (p_tenant_id, v_store.id, v_batch.batch_id, -v_take, 'dispense', coalesce(v_cost, 0),
              'pharmacy_dispense', v_dl);
    end loop;
  end loop;

  return pharmacy.rx_json(p_tenant_id, v_rx.id, v_store.id);
end;
$$;

comment on function pharmacy.dispense(uuid, uuid, jsonb) is
  'Dispense lines of a finalized prescription from one pharmacy store, FEFO over unexpired batches. Idempotent on (tenant, key). A completed line cannot be dispensed again (55000); short stock is 55000.';

revoke all on all functions in schema pharmacy from public, anon, authenticated;
grant execute on function pharmacy.list_queue(uuid, uuid, text) to hms_svc_inventory, service_role;
grant execute on function pharmacy.get_prescription(uuid, uuid, uuid) to hms_svc_inventory, service_role;
grant execute on function pharmacy.dispense(uuid, uuid, jsonb) to hms_svc_inventory, service_role;
grant execute on function identity.can_access_branch(uuid, uuid) to hms_svc_inventory;
