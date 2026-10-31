-- cross-schema: approved (pharmacy schema is hosted by the inventory service per docs/adr/0004-pharmacy-dispensing-in-inventory.md; recreated pharmacy.dispense keeps the same clinical/patient/identity/audit/inventory reads and writes as 20261030090000_inventory_pharmacy_dispense_prescribed_cap.sql)
-- Pharmacy barcode scanning: a dispense line may carry the scanned batchNo. Stock is then taken only from
-- that batch; an expired batch is refused (55000) and an unknown one is not found (P0002). Without a
-- batchNo the server keeps picking FEFO over unexpired batches exactly as before.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

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
  v_cap bigint;
  v_given bigint;
  v_reason text;
  v_batch_no text;
  v_batch_exp date;
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

    -- A scanned pack: take only from that batch. An expired or unknown batch is refused.
    if v_line ? 'batchNo' and jsonb_typeof(v_line -> 'batchNo') not in ('string', 'null') then
      raise exception 'line %: batchNo must be text', v_line_no using errcode = '22023';
    end if;
    v_batch_no := nullif(btrim(coalesce(v_line ->> 'batchNo', '')), '');
    if v_batch_no is not null then
      if length(v_batch_no) > 40 then
        raise exception 'line %: batchNo is too long', v_line_no using errcode = '22023';
      end if;
      select min(b.expiry_date) into v_batch_exp from inventory.batch b
      where b.tenant_id = p_tenant_id and b.item_id = v_item and b.batch_no = v_batch_no and not b.is_deleted;
      if v_batch_exp is null then
        raise exception 'line %: batch % of this item is not in stock here', v_line_no, v_batch_no using errcode = 'P0002';
      end if;
      if v_batch_exp < current_date then
        raise exception 'line %: batch % expired on %; do not dispense it', v_line_no, v_batch_no, v_batch_exp using errcode = '55000';
      end if;
    end if;

    -- FEFO over non-expired batches (or only the scanned batch); the row locks make the availability check race-free.
    perform 1 from inventory.stock_balance_cache sc
    join inventory.batch b on b.id = sc.batch_id
    where sc.store_id = v_store.id and b.item_id = v_item and sc.on_hand_base > 0
    for update of sc;
    select coalesce(sum(sc.on_hand_base), 0) into v_avail
    from inventory.stock_balance_cache sc
    join inventory.batch b on b.id = sc.batch_id
    where sc.store_id = v_store.id and sc.tenant_id = p_tenant_id and b.item_id = v_item
      and sc.on_hand_base > 0 and b.expiry_date >= current_date and not b.is_deleted
        and (v_batch_no is null or b.batch_no = v_batch_no);
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
        and sc.on_hand_base > 0 and b.expiry_date >= current_date and not b.is_deleted
        and (v_batch_no is null or b.batch_no = v_batch_no)
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
$$;

revoke all on function pharmacy.dispense(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function pharmacy.dispense(uuid, uuid, jsonb) to hms_svc_inventory, service_role;
