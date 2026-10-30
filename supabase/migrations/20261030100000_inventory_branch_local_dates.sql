-- cross-schema: approved (reads identity.branches / identity.tenants time zones inside a security-definer helper, the same rule as identity.branch_time_zone_v1; recreates pharmacy.rx_json / pharmacy.dispense, which the inventory service hosts per docs/adr/0004-pharmacy-dispensing-in-inventory.md)
-- #189: drug expiry and drug-licence validity are judged by the branch's local calendar date, not the
-- database session date (UTC on Supabase, i.e. "yesterday" between 00:00 and 05:30 IST).
-- inventory.branch_today / inventory.store_today give the branch-local date (branch override, else the
-- tenant zone, same rule as identity.branch_time_zone_v1). They take no client input beyond an id and
-- return only a date, so they skip the membership check that identity.branch_local_date_v1 does
-- (that check would fail inside triggers run by the service roles).
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function inventory.branch_today(p_branch_id uuid, p_at timestamptz default now())
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select (p_at at time zone coalesce(
    (select coalesce(b.timezone_override, t.time_zone)
       from identity.branches b join identity.tenants t on t.id = b.tenant_id
      where b.id = p_branch_id),
    'Asia/Kolkata'))::date
$$;

create or replace function inventory.store_today(p_store_id uuid, p_at timestamptz default now())
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select inventory.branch_today((select s.branch_id from inventory.store s where s.id = p_store_id), p_at)
$$;

revoke all on function inventory.branch_today(uuid, timestamptz) from public, anon;
revoke all on function inventory.store_today(uuid, timestamptz) from public, anon;
grant execute on function inventory.branch_today(uuid, timestamptz) to authenticated, hms_svc_inventory, service_role;
grant execute on function inventory.store_today(uuid, timestamptz) to authenticated, hms_svc_inventory, service_role;
comment on function inventory.branch_today(uuid, timestamptz) is
  'Calendar date of an instant at the branch (override, else tenant zone; Asia/Kolkata if unknown). Used for expiry and licence checks (#189).';

-- inventory.guard_sale_store_licence: 1 date check(s) now branch-local
CREATE OR REPLACE FUNCTION inventory.guard_sale_store_licence()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.store_kind in ('op_pharmacy', 'ip_pharmacy')
     and (
       new.drug_licence_no is null
       or btrim(new.drug_licence_no) = ''
       or new.licence_valid_to is null
       or new.licence_valid_to < inventory.branch_today(new.branch_id)
     ) then
    raise exception 'a pharmacy needs a current drug licence' using errcode = '23514';
  end if;
  return new;
end;
$function$;

-- inventory.fefo_pick_v1: 1 date check(s) now branch-local
CREATE OR REPLACE FUNCTION inventory.fefo_pick_v1(p_tenant_id uuid, p_store_id uuid, p_item_id uuid, p_qty bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_left bigint := p_qty;
  v_picked bigint := 0;
  v_take bigint;
  v_row record;
  v_batches jsonb := '[]'::jsonb;
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.view');
  if not exists (
    select 1 from inventory.store s
    where s.id = p_store_id and s.tenant_id = p_tenant_id and not s.is_deleted
      and (inventory.bypass_acl() or s.branch_id in (select identity.current_branch_ids(p_tenant_id)))
  ) then
    raise exception 'store not found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from inventory.item i
    where i.id = p_item_id and i.tenant_id = p_tenant_id and not i.is_deleted
  ) then
    raise exception 'item not found' using errcode = 'P0002';
  end if;
  if p_qty is not null and p_qty <= 0 then
    raise exception 'qty must be at least 1' using errcode = '22023';
  end if;

  for v_row in
    select b.id, b.batch_no, b.expiry_date, c.on_hand_base
    from inventory.stock_balance_cache c
    join inventory.batch b on b.id = c.batch_id
    where c.tenant_id = p_tenant_id
      and c.store_id = p_store_id
      and b.item_id = p_item_id
      and c.on_hand_base > 0
      and b.expiry_date >= inventory.store_today(p_store_id)
      and not b.is_deleted
    order by b.expiry_date, b.id
  loop
    if p_qty is null then
      v_take := v_row.on_hand_base;
    else
      exit when v_left <= 0;
      v_take := least(v_row.on_hand_base, v_left);
      v_left := v_left - v_take;
    end if;
    v_picked := v_picked + v_take;
    v_batches := v_batches || jsonb_build_array(jsonb_build_object(
      'batchId', v_row.id,
      'batchNo', v_row.batch_no,
      'expiryDate', v_row.expiry_date,
      'onHandBase', v_row.on_hand_base,
      'pickBase', v_take
    ));
  end loop;

  return jsonb_build_object(
    'requestedBase', p_qty,
    'pickedBase', v_picked,
    'shortBase', case when p_qty is null then 0 else greatest(p_qty - v_picked, 0) end,
    'batches', v_batches
  );
end;
$function$;

-- inventory.stock_on_hand: 2 date check(s) now branch-local
CREATE OR REPLACE FUNCTION inventory.stock_on_hand(p_tenant_id uuid, p_store_id uuid, p_item_id uuid, p_low_only boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform inventory.assert_permission(p_tenant_id, 'inventory.view');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'storeId', s.id,
      'storeCode', s.code,
      'storeName', s.name,
      'itemId', i.id,
      'itemCode', i.code,
      'brandName', i.brand_name,
      'batchId', b.id,
      'batchNo', b.batch_no,
      'expiryDate', b.expiry_date,
      'mrpPaise', b.mrp_paise,
      'purchaseRatePaise', (
        select l.unit_cost_paise
        from inventory.stock_ledger l
        where l.store_id = c.store_id and l.batch_id = c.batch_id
        order by l.seq desc
        limit 1
      ),
      'onHandBase', c.on_hand_base,
      'baseUomCode', i.base_uom_code,
      'minQty', pol.min_qty,
      'lowStock', pol.min_qty is not null and totals.qty < pol.min_qty,
      'expiryState', case
        when b.expiry_date < inventory.store_today(c.store_id) then 'expired'
        when b.expiry_date <= inventory.store_today(c.store_id) + 90 then 'soon'
        else 'ok'
      end
    ) order by s.code, i.code, b.expiry_date, b.id)
    from inventory.stock_balance_cache c
    join inventory.store s on s.id = c.store_id
    join inventory.batch b on b.id = c.batch_id
    join inventory.item i on i.id = b.item_id
    left join inventory.store_item_policy pol
      on pol.tenant_id = c.tenant_id and pol.store_id = c.store_id and pol.item_id = i.id and not pol.is_deleted
    left join lateral (
      select coalesce(sum(c2.on_hand_base), 0) as qty
      from inventory.stock_balance_cache c2
      join inventory.batch b2 on b2.id = c2.batch_id and not b2.is_deleted
      where c2.tenant_id = c.tenant_id and c2.store_id = c.store_id and b2.item_id = i.id
    ) totals on true
    where c.tenant_id = p_tenant_id
      and c.on_hand_base > 0
      and not s.is_deleted
      and not b.is_deleted
      and not i.is_deleted
      and (p_store_id is null or c.store_id = p_store_id)
      and (p_item_id is null or b.item_id = p_item_id)
      and (not p_low_only or (pol.min_qty is not null and totals.qty < pol.min_qty))
      and (inventory.bypass_acl() or s.branch_id in (select identity.current_branch_ids(p_tenant_id)))
  ), '[]'::jsonb);
end;
$function$;

-- pharmacy.rx_json: 1 date check(s) now branch-local
CREATE OR REPLACE FUNCTION pharmacy.rx_json(p_tenant_id uuid, p_id uuid, p_store_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
        'prescribedBase', pharmacy.prescribed_qty(l.dose, l.frequency, l.duration_days),
        'dispensedBase', coalesce((select sum(dl.qty_base) from pharmacy.dispense_line dl
                                   where dl.prescription_line_id = l.id), 0),
        'complete', exists (select 1 from pharmacy.dispense_line dl
                            where dl.prescription_line_id = l.id and dl.completes_line),
        'availableBase', case when p_store_id is null or l.inventory_item_id is null then null else
          coalesce((select sum(sc.on_hand_base) from inventory.stock_balance_cache sc
                    join inventory.batch b on b.id = sc.batch_id
                    where sc.store_id = p_store_id and sc.tenant_id = p_tenant_id
                      and b.item_id = l.inventory_item_id and b.expiry_date >= inventory.store_today(p_store_id)
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
                    'expiryDate', b.expiry_date, 'qtyBase', dl.qty_base, 'completesLine', dl.completes_line,
                    'overrideReason', dl.over_rx_reason)
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
$function$;

-- pharmacy.dispense: 3 date check(s) now branch-local
CREATE OR REPLACE FUNCTION pharmacy.dispense(p_tenant_id uuid, p_key uuid, p_body jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_cap bigint;
  v_given bigint;
  v_reason text;
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
  if v_store.licence_valid_to is null or v_store.licence_valid_to < inventory.store_today(v_store.id) then
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
      and sc.on_hand_base > 0 and b.expiry_date >= inventory.store_today(v_store.id) and not b.is_deleted;
    if v_avail < v_qty then
      raise exception 'line %: only % in stock (unexpired) for %; dispense less and mark it partial',
        v_line_no, v_avail, v_rx_line.medicine_name using errcode = '55000';
    end if;

    -- #187: never give more than the prescription orders unless the pharmacist records why.
    if v_line ? 'overrideReason' and jsonb_typeof(v_line -> 'overrideReason') not in ('string', 'null') then
      raise exception 'line %: overrideReason must be text', v_line_no using errcode = '22023';
    end if;
    v_cap := pharmacy.prescribed_qty(v_rx_line.dose, v_rx_line.frequency, v_rx_line.duration_days);
    v_reason := nullif(btrim(coalesce(v_line ->> 'overrideReason', '')), '');
    if v_reason is not null and length(v_reason) not between 10 and 300 then
      raise exception 'line %: the override reason must be 10 to 300 characters', v_line_no using errcode = '22023';
    end if;
    if v_cap is not null then
      select coalesce(sum(dl.qty_base), 0) into v_given from pharmacy.dispense_line dl
      where dl.prescription_line_id = v_rx_line.id;
      if v_given + v_qty > v_cap then
        if v_reason is null then
          raise exception 'line %: % prescribed and % already given for %; % is more than prescribed. Give less or enter an override reason',
            v_line_no, v_cap, v_given, v_rx_line.medicine_name, v_qty using errcode = '55000';
        end if;
      else
        v_reason := null;  -- a reason is only stored when it was needed
      end if;
    else
      v_reason := null;
    end if;

    v_left := v_qty;
    for v_batch in
      select sc.batch_id, sc.on_hand_base
      from inventory.stock_balance_cache sc
      join inventory.batch b on b.id = sc.batch_id
      where sc.store_id = v_store.id and sc.tenant_id = p_tenant_id and b.item_id = v_item
        and sc.on_hand_base > 0 and b.expiry_date >= inventory.store_today(v_store.id) and not b.is_deleted
      order by b.expiry_date, b.created_on, b.id
    loop
      exit when v_left <= 0;
      v_take := least(v_left, v_batch.on_hand_base);
      v_left := v_left - v_take;
      select l.unit_cost_paise into v_cost from inventory.stock_ledger l
      where l.store_id = v_store.id and l.batch_id = v_batch.batch_id and l.qty_delta_base > 0
      order by l.seq desc limit 1;
      insert into pharmacy.dispense_line (tenant_id, dispense_id, prescription_line_id, item_id, batch_id,
                                          qty_base, completes_line, over_rx_reason)
      values (p_tenant_id, v_dispense, v_rx_line.id, v_item, v_batch.batch_id, v_take, v_complete, v_reason)
      returning id into v_dl;
      insert into inventory.stock_ledger (tenant_id, store_id, batch_id, qty_delta_base, movement,
                                          unit_cost_paise, source_type, source_id)
      values (p_tenant_id, v_store.id, v_batch.batch_id, -v_take, 'dispense', coalesce(v_cost, 0),
              'pharmacy_dispense', v_dl);
    end loop;
  end loop;

  return pharmacy.rx_json(p_tenant_id, v_rx.id, v_store.id);
end;
$function$;
