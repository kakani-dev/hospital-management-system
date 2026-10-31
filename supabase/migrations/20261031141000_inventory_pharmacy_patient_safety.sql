-- cross-schema: approved (pharmacy schema hosted by the inventory service per docs/adr/0004-pharmacy-dispensing-in-inventory.md; reads patient.patients inside security-definer functions only; uses inventory.branch_today for the branch-local age)
-- #275 (patient safety): the dispense queue and the prescription carry what the pharmacist must check
-- before handing over medicine: sex, date of birth (and whether it is estimated), age in years on the
-- branch-local day, and the known allergies (null = not recorded). The pharmacist role keeps its
-- permissions; the data travels with the prescription.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function pharmacy.patient_safety_json(p_patient_id uuid, p_branch_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((
    select jsonb_build_object(
      'patientSex', p.sex,
      'patientDateOfBirth', p.date_of_birth,
      'patientDobEstimated', p.dob_estimated,
      'patientAgeYears', case when p.date_of_birth is null then null
        else extract(year from age(inventory.branch_today(p_branch_id)::timestamp, p.date_of_birth::timestamp))::int end,
      'patientAllergies', nullif(btrim(p.known_allergies), ''))
    from patient.patients p where p.id = p_patient_id),
    jsonb_build_object('patientSex', null, 'patientDateOfBirth', null, 'patientDobEstimated', false,
                       'patientAgeYears', null, 'patientAllergies', null))
$$;
revoke execute on function pharmacy.patient_safety_json(uuid, uuid) from public, anon, authenticated;

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
    || pharmacy.patient_safety_json(c.patient_id, c.branch_id)
  from clinical.consultations c
  join patient.patients p on p.id = c.patient_id and p.tenant_id = c.tenant_id
  join appointment.practitioners pr on pr.id = c.practitioner_id
  where c.id = p_id and c.tenant_id = p_tenant_id
$function$;

CREATE OR REPLACE FUNCTION pharmacy.list_queue(p_tenant_id uuid, p_branch_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_status text := coalesce(nullif(btrim(p_status), ''), 'open');
  v_days integer;
begin
  perform pharmacy.assert_permission(p_tenant_id, 'pharmacy.view');
  if v_status not in ('open', 'all', 'pending', 'partial', 'dispensed') then
    raise exception 'status must be open, all, pending, partial, or dispensed' using errcode = '22023';
  end if;
  if p_branch_id is not null and not identity.can_access_branch(p_tenant_id, p_branch_id) then
    raise exception 'branch out of scope' using errcode = '42501';
  end if;
  v_days := pharmacy.rx_validity_days(p_tenant_id);
  return coalesce((
    select jsonb_agg(q.row order by q.finalized_on, q.id)
    from (
      select c.id, c.finalized_on, jsonb_build_object(
        'id', c.id, 'branchId', c.branch_id, 'patientId', c.patient_id,
        'patientName', p.first_name || ' ' || p.last_name, 'patientMrn', p.mrn,
        'doctorName', pr.display_name, 'finalizedOn', c.finalized_on,
        'validThrough', d.valid_through, 'expired', d.today > d.valid_through,
        'lineCount', (select count(*) from clinical.prescription_lines l
                      where l.consultation_id = c.id and not l.is_deleted),
        'status', s.status) || pharmacy.patient_safety_json(c.patient_id, c.branch_id) as row
      from clinical.consultations c
      join patient.patients p on p.id = c.patient_id and p.tenant_id = c.tenant_id
      join appointment.practitioners pr on pr.id = c.practitioner_id
      cross join lateral (select inventory.branch_today(c.branch_id, c.finalized_on) + v_days as valid_through,
                                 inventory.branch_today(c.branch_id) as today) d
      cross join lateral (select pharmacy.rx_status(c.id) as status) s
      where c.tenant_id = p_tenant_id
        and c.status = 'finalized' and not c.is_deleted
        and (p_branch_id is null or c.branch_id = p_branch_id)
        and identity.can_access_branch(p_tenant_id, c.branch_id)
        and not pharmacy.is_superseded(c.id)
        and exists (select 1 from clinical.prescription_lines l where l.consultation_id = c.id and not l.is_deleted)
        -- Expired prescriptions leave the working queue (open / pending / partial); history views keep them.
        and (v_status in ('all', 'dispensed') or d.today <= d.valid_through)
        and (v_status = 'all'
             or (v_status = 'open' and s.status in ('pending', 'partial'))
             or s.status = v_status)
      order by c.finalized_on, c.id
      limit 200
    ) q), '[]'::jsonb);
end;
$function$;
