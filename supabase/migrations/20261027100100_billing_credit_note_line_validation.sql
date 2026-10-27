-- #144: clear errors for a credit note line. billing.create_credit_note gave the same
-- "credit quantity exceeds the amount not already credited" for every bad line: an unknown key
-- (e.g. billLineId instead of lineId), a line that is not on the bill, a missing, non-numeric or
-- non-positive quantity, and a real over-credit. Now:
--   * lineId is the line key; billLineId is accepted as an alias (the bill line DTO name);
--   * a missing / malformed / foreign line, a bad quantity and a fully credited line each have
--     their own 22023 message; the over-credit message (CRN-002) is unchanged;
--   * quantity omitted = credit everything still not credited on that line;
--   * the same line twice in one note counts against what is left (no over-credit within a note).
-- Same signature, owner and grants; billing schema only.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.create_credit_note(p_tenant_id uuid, p_bill_id uuid, p_body jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_src billing.bill%rowtype;
  v_note uuid;
  v_line jsonb;
  v_src_line billing.bill_line%rowtype;
  v_line_key text;
  v_line_id uuid;
  v_qty_raw jsonb;
  v_qty numeric;
  v_left numeric;
  v_n int := 0;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  if p_body is null or jsonb_typeof(p_body) <> 'object'
     or (p_body ? 'lines' and jsonb_typeof(p_body -> 'lines') <> 'array') then
    raise exception 'lines must be a list of {lineId, quantity}' using errcode = '22023';
  end if;
  select * into v_src from billing.bill
  where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted and status = 'finalized' and bill_kind <> 'credit_note'
  for update;
  if v_src.id is null then
    raise exception 'finalized bill not found' using errcode = 'P0002';
  end if;
  insert into billing.bill (tenant_id, account_id, bill_kind, reverses_bill_id, payer_type)
  values (p_tenant_id, v_src.account_id, 'credit_note', v_src.id, v_src.payer_type)
  returning id into v_note;
  for v_line in select * from jsonb_array_elements(coalesce(p_body -> 'lines', '[]'::jsonb))
  loop
    if jsonb_typeof(v_line) <> 'object' then
      raise exception 'each credit note line must be an object {lineId, quantity}' using errcode = '22023';
    end if;
    v_line_key := coalesce(v_line ->> 'lineId', v_line ->> 'billLineId');
    if v_line_key is null or btrim(v_line_key) = '' then
      raise exception 'each credit note line needs a lineId (the bill line to credit)' using errcode = '22023';
    end if;
    if v_line_key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'lineId must be the id of a line on this bill' using errcode = '22023';
    end if;
    v_line_id := v_line_key::uuid;
    select * into v_src_line from billing.bill_line
    where id = v_line_id and bill_id = p_bill_id and tenant_id = p_tenant_id and not is_deleted;
    if v_src_line.id is null then
      raise exception 'credit note line not found on this bill' using errcode = '22023';
    end if;
    if v_src_line.quantity <= 0 then
      raise exception 'only a charged line can be credited' using errcode = '22023';
    end if;
    v_left := v_src_line.quantity - billing.line_credited_qty(v_src_line.id)
      - coalesce((select sum(-l.quantity) from billing.bill_line l
                  where l.bill_id = v_note and l.reverses_line_id = v_src_line.id and not l.is_deleted), 0);
    if v_left <= 0 then
      raise exception 'this line is already fully credited' using errcode = '22023';
    end if;
    v_qty_raw := v_line -> 'quantity';
    if v_qty_raw is null or jsonb_typeof(v_qty_raw) = 'null' then
      v_qty := v_left;
    elsif jsonb_typeof(v_qty_raw) = 'number' then
      v_qty := (v_qty_raw #>> '{}')::numeric;
    elsif jsonb_typeof(v_qty_raw) = 'string' and (v_qty_raw #>> '{}') ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' then
      v_qty := (v_qty_raw #>> '{}')::numeric;
    else
      raise exception 'credit quantity must be a number' using errcode = '22023';
    end if;
    if v_qty <= 0 then
      raise exception 'credit quantity must be more than zero' using errcode = '22023';
    end if;
    if v_qty > v_left then
      raise exception 'credit quantity exceeds the amount not already credited' using errcode = '22023';
    end if;
    v_n := v_n + 1;
    insert into billing.bill_line (
      tenant_id, bill_id, line_no, service_item_id, price_list_item_id, practitioner_id,
      quantity, unit_price_paise, tax_rate_bp, reverses_line_id)
    values (
      p_tenant_id, v_note, v_n, v_src_line.service_item_id, v_src_line.price_list_item_id,
      v_src_line.practitioner_id, -v_qty, v_src_line.unit_price_paise, v_src_line.tax_rate_bp, v_src_line.id);
  end loop;
  if v_n = 0 then
    raise exception 'a credit note needs a line' using errcode = '22023';
  end if;
  return billing.finalize_bill(p_tenant_id, v_note);
end;
$$;

comment on function billing.create_credit_note(uuid, uuid, jsonb) is
  'Credit note on a finalized bill. lines: [{lineId (alias billLineId), quantity (default: all not yet credited)}]. Each bad line has its own 22023 message (#144).';
