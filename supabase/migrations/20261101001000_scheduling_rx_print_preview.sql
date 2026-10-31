-- cross-schema: approved (the scheduling module owns clinical + appointment; the print payload reads identity/patient read models and the platform onboarding default, exactly as clinical.consultation_print already does)
-- One-screen consultation (#rx-one-screen): the doctor sees a live A5/A4 preview of the prescription while
-- writing it. consultation_print_preview returns the same payload as consultation_print (hospital, doctor
-- registration, patient, paperSize) for a draft too; the web overlays the unsaved edits. The printable
-- copy stays finalized-only: consultation_print keeps its draft check and delegates to the preview.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function clinical.consultation_print_preview(p_tenant_id uuid, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v clinical.consultations%rowtype;
  v_branch jsonb;
begin
  v := clinical.load_visible(p_tenant_id, p_id);
  select jsonb_build_object('name', h.name, 'address', h.address) into v_branch
  from identity.branch_bill_header_v1(p_tenant_id, v.branch_id) h;
  return clinical.consultation_json(p_id) || jsonb_build_object(
    'branch', v_branch,
    'tenantName', (select t.name from identity.tenants t where t.id = p_tenant_id),
    'timeZone', identity.branch_time_zone_v1(v.branch_id),
    'paperSize', coalesce(
      (select s.rx_paper_size from appointment.tenant_settings s where s.tenant_id = p_tenant_id and not s.is_deleted),
      (select d.settings ->> 'rx_paper_size' from identity.onboarding_defaults d
        where d.target = 'appointment.tenant_settings' and not d.is_deleted)),
    'doctor', (select jsonb_build_object('name', p.display_name, 'registrationNumber', p.registration_number,
                                         'council', p.council_name, 'qualifications', p.qualifications)
               from appointment.practitioners p where p.id = v.practitioner_id),
    'patient', (select jsonb_build_object('mrn', p.mrn, 'name', btrim(p.first_name || ' ' || coalesce(p.last_name, '')),
                                          'dateOfBirth', p.date_of_birth, 'sex', p.sex)
                from patient.patients p where p.id = v.patient_id));
end;
$$;


create or replace function clinical.consultation_print(p_tenant_id uuid, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v clinical.consultations%rowtype;
begin
  v := clinical.load_visible(p_tenant_id, p_id);
  if v.status <> 'finalized' then
    raise exception 'a draft prescription cannot be printed; finalize it first' using errcode = '55000';
  end if;
  return clinical.consultation_print_preview(p_tenant_id, p_id);
end;
$$;

revoke all on function clinical.consultation_print_preview(uuid, uuid) from public, anon, authenticated;
grant execute on function clinical.consultation_print_preview(uuid, uuid) to hms_svc_scheduling, hms_api, service_role;
