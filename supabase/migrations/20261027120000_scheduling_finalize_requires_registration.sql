-- cross-schema: approved (no new cross-schema reads; same patient.patients.deleted_at read and
-- messaging.enqueue call as 20261026090000. appointment.practitioners is the same service.)
-- #128: a prescription can only be finalized by a doctor with a council registration number.
-- DOC-21 / NMC RMP (Professional Conduct) Regulations 2023: the registration number must appear on
-- the prescription. clinical.finalize_consultation keeps its signature, owner and grants; the only
-- change is the new 22023 (-> 400) check. Already-finalized prescriptions are not touched, and a
-- repeat finalize of one still returns it. Print (clinical.consultation_print) is unchanged: it
-- already returns registrationNumber, council, dateOfBirth and sex; the web print view now renders them.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function clinical.finalize_consultation(p_tenant_id uuid, p_id uuid, p_row_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v clinical.consultations%rowtype;
begin
  v := clinical.load_visible(p_tenant_id, p_id, true);
  perform clinical.assert_author(p_tenant_id, v.practitioner_id);
  if v.status = 'finalized' then
    return clinical.consultation_json(p_id);
  end if;
  if p_row_version is null or p_row_version <> v.row_version then
    raise exception 'stale_version: the consultation was changed elsewhere; reload' using errcode = '40001';
  end if;
  if v.chief_complaint is null and v.diagnosis_text is null then
    raise exception 'enter a chief complaint or a diagnosis before finalizing' using errcode = '22023';
  end if;
  -- #128: NMC (Professional Conduct) Regulations 2023 require the registration number on every
  -- prescription, so a doctor without one cannot finalize. Checked after the idempotent return, so
  -- an already-finalized prescription still answers a repeat finalize.
  if not exists (select 1 from appointment.practitioners p
                 where p.id = v.practitioner_id and nullif(btrim(p.registration_number), '') is not null) then
    raise exception 'add your council registration number (Administration > Practitioners) before finalizing; it must be printed on the prescription'
      using errcode = '22023';
  end if;
  if exists (select 1 from patient.patients p where p.id = v.patient_id and p.deleted_at is not null) then
    raise exception 'the patient record is deleted' using errcode = '55000';
  end if;
  update clinical.consultations
     set status = 'finalized', finalized_on = now(), finalized_by = auth.uid(), row_version = row_version + 1
   where id = p_id;
  -- Identifiers only: no clinical text leaves the clinical schema (billing never sees notes).
  perform messaging.enqueue(p_tenant_id, 'consultation', p_id, 'consultation.finalized', jsonb_build_object(
    'consultationId', p_id, 'rootId', v.root_id, 'version', v.version, 'branchId', v.branch_id,
    'patientId', v.patient_id, 'practitionerId', v.practitioner_id, 'appointmentId', v.appointment_id,
    'lineCount', (select count(*) from clinical.prescription_lines l where l.consultation_id = p_id and not l.is_deleted)));
  return clinical.consultation_json(p_id);
end;
$$;
