-- cross-schema: approved (the scheduling module owns clinical + appointment; the print payload reads the platform onboarding default from identity.onboarding_defaults, as consultation_print already reads identity/patient read models)
-- Prescription print paper size is a per-tenant setting (A5 by default, A4 if the hospital prints
-- on A4 letterhead). clinical.consultation_print returns it as paperSize so the web print view sets
-- @page from data, not code. Tenants without a settings row fall back to the platform onboarding
-- default (identity.onboarding_defaults), so the default lives in config only.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table appointment.tenant_settings
  add column if not exists rx_paper_size text;
update appointment.tenant_settings set rx_paper_size = 'A5' where rx_paper_size is null;
alter table appointment.tenant_settings
  alter column rx_paper_size set default 'A5',
  alter column rx_paper_size set not null;
do $$ begin
  alter table appointment.tenant_settings
    add constraint tenant_settings_rx_paper_size_check check (rx_paper_size in ('A5', 'A4'));
exception when duplicate_object then null; end $$;
comment on column appointment.tenant_settings.rx_paper_size is
  'Paper size for printed prescriptions: A5 (default, typical Indian OPD pad) or A4 letterhead.';

update identity.onboarding_defaults
   set settings = settings || '{"rx_paper_size": "A5"}'::jsonb
 where target = 'appointment.tenant_settings' and not settings ? 'rx_paper_size';

create or replace function clinical.consultation_print(p_tenant_id uuid, p_id uuid)
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
  if v.status <> 'finalized' then
    raise exception 'a draft prescription cannot be printed; finalize it first' using errcode = '55000';
  end if;
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
