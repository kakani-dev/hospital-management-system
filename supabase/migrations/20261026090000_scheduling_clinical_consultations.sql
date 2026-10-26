-- cross-schema: approved (new schema clinical, owned by the scheduling service until a clinical service
-- exists; see docs/adr/0003-clinical-consultations-in-scheduling.md. Reads appointment.queue_entries /
-- practitioners (same service), patient.patients.deleted_at and identity.branch_bill_header_v1 inside
-- security-definer functions, RLS helpers identity.current_tenant_ids / can_access_branch /
-- has_tenant_permission, audit.* trigger functions, messaging.enqueue for the finalize event, and adds
-- the clinical.view / clinical.write permission names to identity.role_permissions.)
-- Consultation + prescription v1. A finalized consultation is immutable; a correction is a new version.
-- Tenant id is never taken from the client: the API passes the server-resolved tenant and every function
-- checks it against the caller's memberships.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create schema if not exists clinical;
revoke all on schema clinical from public, anon, authenticated;
grant usage on schema clinical to hms_svc_scheduling, hms_api, service_role;

-- -------------------------------------------------------------- permissions ----
insert into identity.role_permissions (role, permission) values
  ('doctor', 'clinical.view'),
  ('doctor', 'clinical.write'),
  ('nurse', 'clinical.view'),
  ('tenant_admin', 'clinical.view')
on conflict do nothing;

-- ------------------------------------------------------------------- tables ----
create table clinical.consultations (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references identity.tenants (id) on delete restrict,
  branch_id        uuid not null,
  patient_id       uuid not null,
  practitioner_id  uuid not null,
  queue_entry_id   uuid not null,
  appointment_id   uuid,
  root_id          uuid not null,
  version          integer not null default 1,
  supersedes_id    uuid references clinical.consultations (id) on delete restrict,
  status           text not null default 'draft',
  chief_complaint  text,
  notes            text,
  diagnosis_text   text,
  diagnosis_code   text,
  follow_up_date   date,
  advice           text,
  finalized_on     timestamptz,
  finalized_by     uuid,
  row_version      integer not null default 1,
  created_on       timestamptz not null default now(),
  created_by       uuid not null,
  updated_on       timestamptz not null default now(),
  updated_by       uuid not null,
  is_deleted       boolean not null default false,
  constraint consultations_tenant_id_id_key unique (tenant_id, id),
  constraint consultations_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete restrict,
  constraint consultations_patient_same_tenant
    foreign key (tenant_id, patient_id) references patient.patients (tenant_id, id) on delete restrict,
  constraint consultations_practitioner_same_tenant
    foreign key (tenant_id, practitioner_id) references appointment.practitioners (tenant_id, id) on delete restrict,
  constraint consultations_queue_same_tenant
    foreign key (tenant_id, queue_entry_id) references appointment.queue_entries (tenant_id, id) on delete restrict,
  constraint consultations_status_valid check (status in ('draft', 'finalized')),
  constraint consultations_version_positive check (version > 0 and row_version > 0),
  constraint consultations_finalized_stamp check ((status = 'finalized') = (finalized_on is not null)),
  constraint consultations_versions_chain check ((version = 1) = (supersedes_id is null)),
  constraint consultations_text_len check (
    coalesce(length(chief_complaint), 0) <= 2000 and coalesce(length(notes), 0) <= 8000
    and coalesce(length(diagnosis_text), 0) <= 1000 and coalesce(length(diagnosis_code), 0) <= 20
    and coalesce(length(advice), 0) <= 4000)
);
-- Double-submit guards: one first version per queue entry, one correction per version.
create unique index consultations_one_per_visit on clinical.consultations (tenant_id, queue_entry_id)
  where version = 1 and not is_deleted;
create unique index consultations_one_correction on clinical.consultations (supersedes_id)
  where supersedes_id is not null and not is_deleted;
create unique index consultations_root_version on clinical.consultations (root_id, version);
create index consultations_patient_idx on clinical.consultations (tenant_id, patient_id, created_on desc)
  where not is_deleted;
comment on table clinical.consultations is
  'OPD consultation and its prescription header. Times are UTC (timestamptz); the UI shows the branch time zone. A finalized row is immutable; corrections are new versions (root_id, version, supersedes_id). row_version is the optimistic-concurrency token.';

create table clinical.prescription_lines (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references identity.tenants (id) on delete restrict,
  consultation_id  uuid not null,
  line_no          smallint not null,
  medicine_name    text not null,
  inventory_item_id uuid,
  strength         text,
  dose             text not null,
  frequency        text not null,
  duration_days    smallint not null,
  route            text,
  food_timing      text,
  instructions     text,
  created_on       timestamptz not null default now(),
  created_by       uuid not null,
  updated_on       timestamptz not null default now(),
  updated_by       uuid not null,
  is_deleted       boolean not null default false,
  constraint prescription_lines_consultation_same_tenant
    foreign key (tenant_id, consultation_id) references clinical.consultations (tenant_id, id) on delete restrict,
  constraint prescription_lines_line_key unique (consultation_id, line_no),
  constraint prescription_lines_medicine check (length(btrim(medicine_name)) between 1 and 200),
  constraint prescription_lines_dose check (length(btrim(dose)) between 1 and 60),
  constraint prescription_lines_frequency check (length(btrim(frequency)) between 1 and 40),
  constraint prescription_lines_duration check (duration_days between 1 and 365),
  constraint prescription_lines_food check (food_timing is null or food_timing in ('before_food', 'after_food', 'with_food', 'any')),
  constraint prescription_lines_text_len check (
    coalesce(length(strength), 0) <= 60 and coalesce(length(route), 0) <= 40 and coalesce(length(instructions), 0) <= 500)
);
comment on table clinical.prescription_lines is
  'Prescription lines of one consultation version. Free-text medicine name; inventory_item_id is an optional soft link (no cross-service FK).';

create trigger consultations_audit_columns before insert or update on clinical.consultations
  for each row execute function audit.stamp_audit_columns();
create trigger consultations_tenant_immutable before update on clinical.consultations
  for each row execute function audit.prevent_tenant_change();
create trigger consultations_audit_log after insert or update or delete on clinical.consultations
  for each row execute function audit.log_row_change();
create trigger prescription_lines_audit_columns before insert or update on clinical.prescription_lines
  for each row execute function audit.stamp_audit_columns();
create trigger prescription_lines_tenant_immutable before update on clinical.prescription_lines
  for each row execute function audit.prevent_tenant_change();
create trigger prescription_lines_audit_log after insert or update or delete on clinical.prescription_lines
  for each row execute function audit.log_row_change();

-- Immutability: nothing may change a finalized consultation or its lines (not even the owner role).
create or replace function clinical.block_finalized_change()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status text;
begin
  if tg_table_name = 'consultations' then
    if old.status = 'finalized' then
      raise exception 'a finalized consultation cannot be changed; create a correction' using errcode = '55000';
    end if;
    if tg_op = 'DELETE' then
      raise exception 'consultations are never hard-deleted' using errcode = '55000';
    end if;
    return new;
  end if;
  select c.status into v_status from clinical.consultations c
  where c.id = case when tg_op = 'INSERT' then new.consultation_id else old.consultation_id end;
  if v_status = 'finalized' then
    raise exception 'a finalized consultation cannot be changed; create a correction' using errcode = '55000';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
create trigger consultations_immutable before update or delete on clinical.consultations
  for each row execute function clinical.block_finalized_change();
create trigger prescription_lines_immutable before insert or update or delete on clinical.prescription_lines
  for each row execute function clinical.block_finalized_change();

-- RLS: fail closed. Writes go only through the functions below (security definer, explicit checks).
alter table clinical.consultations enable row level security;
alter table clinical.prescription_lines enable row level security;
revoke all on clinical.consultations, clinical.prescription_lines from public, anon, authenticated;
grant select on clinical.consultations, clinical.prescription_lines to hms_svc_scheduling, hms_api;
create policy consultations_read on clinical.consultations for select to hms_svc_scheduling, hms_api
  using (tenant_id in (select identity.current_tenant_ids())
         and identity.can_access_branch(tenant_id, branch_id)
         and identity.has_tenant_permission(tenant_id, 'clinical.view'));
create policy prescription_lines_read on clinical.prescription_lines for select to hms_svc_scheduling, hms_api
  using (exists (select 1 from clinical.consultations c where c.id = consultation_id));

-- ------------------------------------------------------------------ outbox ----
alter table messaging.outbox drop constraint outbox_aggregate_type_valid;
alter table messaging.outbox add constraint outbox_aggregate_type_valid
  check (aggregate_type in ('appointment', 'queue_entry', 'tenant', 'email_message', 'patient', 'billing', 'privacy', 'consultation'));

create or replace function messaging.set_outbox_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.source_service := case new.aggregate_type
    when 'appointment' then 'scheduling'
    when 'queue_entry' then 'scheduling'
    when 'consultation' then 'scheduling'
    when 'tenant' then 'identity'
    when 'email_message' then 'identity'
    when 'patient' then 'patients'
    when 'billing' then 'billing'
    when 'privacy' then 'privacy'
  end;
  if new.source_service is null then
    raise exception 'no owning service for aggregate type %', new.aggregate_type using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function messaging.set_outbox_source() from public;

-- ----------------------------------------------------------------- helpers ----
create or replace function clinical.assert_tenant(p_tenant_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'consultation not found' using errcode = 'P0002';
  end if;
end;
$$;

-- Loads a consultation the caller may see: foreign tenant / unknown -> P0002, other branch or no
-- clinical.view -> 42501.
create or replace function clinical.load_visible(p_tenant_id uuid, p_id uuid, p_lock boolean default false)
returns clinical.consultations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v clinical.consultations%rowtype;
begin
  perform clinical.assert_tenant(p_tenant_id);
  if p_lock then
    select * into v from clinical.consultations where id = p_id and tenant_id = p_tenant_id and not is_deleted for update;
  else
    select * into v from clinical.consultations where id = p_id and tenant_id = p_tenant_id and not is_deleted;
  end if;
  if v.id is null then
    raise exception 'consultation not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_permission(p_tenant_id, 'clinical.view')
     or not identity.can_access_branch(p_tenant_id, v.branch_id) then
    raise exception 'not permitted to view this consultation' using errcode = '42501';
  end if;
  return v;
end;
$$;

-- Write access: clinical.write AND the practitioner of the visit is linked to the caller's login.
create or replace function clinical.assert_author(p_tenant_id uuid, p_practitioner_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not identity.has_tenant_permission(p_tenant_id, 'clinical.write')
     or not exists (select 1 from appointment.practitioners p
                    where p.tenant_id = p_tenant_id and p.id = p_practitioner_id
                      and p.user_id = auth.uid() and not p.is_deleted) then
    raise exception 'only the consulting doctor can write this consultation' using errcode = '42501';
  end if;
end;
$$;

create or replace function clinical.consultation_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', c.id, 'branchId', c.branch_id, 'patientId', c.patient_id, 'practitionerId', c.practitioner_id,
    'practitionerName', pr.display_name,
    'queueEntryId', c.queue_entry_id, 'appointmentId', c.appointment_id,
    'rootId', c.root_id, 'version', c.version, 'supersedesId', c.supersedes_id,
    'isLatest', not exists (select 1 from clinical.consultations n where n.supersedes_id = c.id and not n.is_deleted),
    'status', c.status, 'chiefComplaint', c.chief_complaint, 'notes', c.notes,
    'diagnosisText', c.diagnosis_text, 'diagnosisCode', c.diagnosis_code,
    'followUpDate', c.follow_up_date, 'advice', c.advice,
    'finalizedOn', c.finalized_on, 'rowVersion', c.row_version,
    'createdOn', c.created_on, 'updatedOn', c.updated_on,
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'lineNo', l.line_no, 'medicineName', l.medicine_name, 'inventoryItemId', l.inventory_item_id,
        'strength', l.strength, 'dose', l.dose, 'frequency', l.frequency, 'durationDays', l.duration_days,
        'route', l.route, 'foodTiming', l.food_timing, 'instructions', l.instructions) order by l.line_no)
      from clinical.prescription_lines l where l.consultation_id = c.id and not l.is_deleted), '[]'::jsonb))
  from clinical.consultations c
  join appointment.practitioners pr on pr.id = c.practitioner_id
  where c.id = p_id;
$$;

-- Replace header fields + lines from a JSON body. Validation errors are 22023 with a field message.
create or replace function clinical.apply_body(p_id uuid, p_tenant_id uuid, p_body jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_line jsonb;
  v_no smallint := 0;
  v_dur numeric;
  v_food text;
begin
  if p_body is null or jsonb_typeof(p_body) <> 'object' then
    raise exception 'body must be a JSON object' using errcode = '22023';
  end if;
  if p_body ? 'lines' and jsonb_typeof(p_body -> 'lines') <> 'array' then
    raise exception 'lines must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_body -> 'lines', '[]'::jsonb)) > 50 then
    raise exception 'at most 50 prescription lines' using errcode = '22023';
  end if;
  update clinical.consultations set
    chief_complaint = nullif(btrim(p_body ->> 'chiefComplaint'), ''),
    notes = nullif(btrim(p_body ->> 'notes'), ''),
    diagnosis_text = nullif(btrim(p_body ->> 'diagnosisText'), ''),
    diagnosis_code = upper(nullif(btrim(p_body ->> 'diagnosisCode'), '')),
    follow_up_date = nullif(p_body ->> 'followUpDate', '')::date,
    advice = nullif(btrim(p_body ->> 'advice'), '')
  where id = p_id;
  delete from clinical.prescription_lines where consultation_id = p_id;
  for v_line in select * from jsonb_array_elements(coalesce(p_body -> 'lines', '[]'::jsonb)) loop
    v_no := v_no + 1;
    if length(btrim(coalesce(v_line ->> 'medicineName', ''))) = 0 then
      raise exception 'line %: medicine name is required', v_no using errcode = '22023';
    end if;
    if length(btrim(coalesce(v_line ->> 'dose', ''))) = 0 or btrim(v_line ->> 'dose') ~ '^-?0*([.,]0*)?$'
       or btrim(v_line ->> 'dose') ~ '^-' then
      raise exception 'line %: dose must be more than 0', v_no using errcode = '22023';
    end if;
    if length(btrim(coalesce(v_line ->> 'frequency', ''))) = 0 then
      raise exception 'line %: frequency is required', v_no using errcode = '22023';
    end if;
    begin
      v_dur := (v_line ->> 'durationDays')::numeric;
    exception when others then
      v_dur := null;
    end;
    if v_dur is null or v_dur <= 0 or v_dur > 365 or v_dur <> trunc(v_dur) then
      raise exception 'line %: duration must be 1 to 365 whole days', v_no using errcode = '22023';
    end if;
    v_food := nullif(btrim(v_line ->> 'foodTiming'), '');
    if v_food is not null and v_food not in ('before_food', 'after_food', 'with_food', 'any') then
      raise exception 'line %: food timing must be before_food, after_food, with_food or any', v_no using errcode = '22023';
    end if;
    begin
      insert into clinical.prescription_lines (
        tenant_id, consultation_id, line_no, medicine_name, inventory_item_id, strength, dose, frequency,
        duration_days, route, food_timing, instructions)
      values (
        p_tenant_id, p_id, v_no, btrim(v_line ->> 'medicineName'),
        nullif(v_line ->> 'inventoryItemId', '')::uuid,
        nullif(btrim(v_line ->> 'strength'), ''), btrim(v_line ->> 'dose'), btrim(v_line ->> 'frequency'),
        v_dur::smallint, nullif(btrim(v_line ->> 'route'), ''), v_food, nullif(btrim(v_line ->> 'instructions'), ''));
    exception when check_violation or invalid_text_representation then
      raise exception 'line %: a value is too long or invalid', v_no using errcode = '22023';
    end;
  end loop;
exception
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'followUpDate must be a date (yyyy-mm-dd)' using errcode = '22023';
  when check_violation then
    raise exception 'a consultation field is too long' using errcode = '22023';
end;
$$;

-- ---------------------------------------------------------------- the API ----
-- Start (or reopen) the draft for a checked-in visit. Idempotent: a repeat returns the same draft.
create or replace function clinical.start_consultation(p_tenant_id uuid, p_queue_entry_id uuid, p_appointment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q record;
  v_id uuid;
begin
  perform clinical.assert_tenant(p_tenant_id);
  if p_queue_entry_id is null and p_appointment_id is null then
    raise exception 'queueEntryId or appointmentId is required' using errcode = '22023';
  end if;
  select q.id, q.branch_id, q.patient_id, q.practitioner_id, q.appointment_id, q.status into v_q
  from appointment.queue_entries q
  where q.tenant_id = p_tenant_id
    and (q.id = p_queue_entry_id or (p_queue_entry_id is null and q.appointment_id = p_appointment_id))
  order by q.checked_in_at desc limit 1
  for update;
  if v_q.id is null then
    if p_appointment_id is not null and exists (
         select 1 from appointment.appointments a where a.id = p_appointment_id and a.tenant_id = p_tenant_id) then
      raise exception 'the patient is not checked in for this appointment' using errcode = '55000';
    end if;
    raise exception 'queue entry not found' using errcode = 'P0002';
  end if;
  if not identity.can_access_branch(p_tenant_id, v_q.branch_id) then
    raise exception 'not permitted for this branch' using errcode = '42501';
  end if;
  if v_q.practitioner_id is null then
    raise exception 'assign a doctor to this visit before the consultation' using errcode = '55000';
  end if;
  perform clinical.assert_author(p_tenant_id, v_q.practitioner_id);
  if exists (select 1 from patient.patients p where p.id = v_q.patient_id and p.deleted_at is not null) then
    raise exception 'the patient record is deleted' using errcode = '55000';
  end if;

  select c.id into v_id from clinical.consultations c
  where c.tenant_id = p_tenant_id and c.queue_entry_id = v_q.id and c.version = 1 and not c.is_deleted;
  if v_id is not null then
    -- Reopen: the latest version of this visit (draft or finalized).
    select c.id into v_id from clinical.consultations c
    where c.root_id = v_id and not c.is_deleted order by c.version desc limit 1;
    return clinical.consultation_json(v_id);
  end if;
  if v_q.status not in ('waiting', 'in_consultation') then
    raise exception 'the patient is not checked in (queue status %)', v_q.status using errcode = '55000';
  end if;

  v_id := gen_random_uuid();
  insert into clinical.consultations (id, tenant_id, branch_id, patient_id, practitioner_id, queue_entry_id, appointment_id, root_id)
  values (v_id, p_tenant_id, v_q.branch_id, v_q.patient_id, v_q.practitioner_id, v_q.id, v_q.appointment_id, v_id);
  return clinical.consultation_json(v_id);
end;
$$;

create or replace function clinical.get_consultation(p_tenant_id uuid, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v clinical.consultations%rowtype;
begin
  v := clinical.load_visible(p_tenant_id, p_id);
  return clinical.consultation_json(v.id);
end;
$$;

-- Save a draft. p_row_version must match (optimistic concurrency, 40001 on mismatch).
create or replace function clinical.save_consultation(p_tenant_id uuid, p_id uuid, p_row_version integer, p_body jsonb)
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
    raise exception 'a finalized consultation cannot be changed; create a correction' using errcode = '55000';
  end if;
  if p_row_version is null or p_row_version <> v.row_version then
    raise exception 'stale_version: the consultation was changed elsewhere; reload' using errcode = '40001';
  end if;
  perform clinical.apply_body(p_id, p_tenant_id, p_body);
  update clinical.consultations set row_version = row_version + 1 where id = p_id;
  return clinical.consultation_json(p_id);
end;
$$;

-- Finalize. Idempotent: finalizing a finalized consultation returns it unchanged (no second event).
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

-- Correction: a new draft version copied from the latest finalized one. Idempotent per version.
create or replace function clinical.revise_consultation(p_tenant_id uuid, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v clinical.consultations%rowtype;
  v_new uuid;
begin
  v := clinical.load_visible(p_tenant_id, p_id, true);
  perform clinical.assert_author(p_tenant_id, v.practitioner_id);
  select c.id into v_new from clinical.consultations c where c.supersedes_id = p_id and not c.is_deleted;
  if v_new is not null then
    return clinical.consultation_json(v_new);
  end if;
  if v.status <> 'finalized' then
    raise exception 'only a finalized consultation can be corrected; edit the draft instead' using errcode = '55000';
  end if;
  v_new := gen_random_uuid();
  insert into clinical.consultations (
    id, tenant_id, branch_id, patient_id, practitioner_id, queue_entry_id, appointment_id, root_id, version,
    supersedes_id, chief_complaint, notes, diagnosis_text, diagnosis_code, follow_up_date, advice)
  values (
    v_new, v.tenant_id, v.branch_id, v.patient_id, v.practitioner_id, v.queue_entry_id, v.appointment_id, v.root_id,
    v.version + 1, v.id, v.chief_complaint, v.notes, v.diagnosis_text, v.diagnosis_code, v.follow_up_date, v.advice);
  insert into clinical.prescription_lines (
    tenant_id, consultation_id, line_no, medicine_name, inventory_item_id, strength, dose, frequency,
    duration_days, route, food_timing, instructions)
  select tenant_id, v_new, line_no, medicine_name, inventory_item_id, strength, dose, frequency,
         duration_days, route, food_timing, instructions
  from clinical.prescription_lines where consultation_id = p_id and not is_deleted;
  return clinical.consultation_json(v_new);
end;
$$;

-- Patient history: every version the caller may see, newest first.
create or replace function clinical.patient_consultations(p_tenant_id uuid, p_patient_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform clinical.assert_tenant(p_tenant_id);
  if not identity.has_tenant_permission(p_tenant_id, 'clinical.view') then
    raise exception 'not permitted to view consultations' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(clinical.consultation_json(c.id) order by c.created_on desc, c.version desc)
    from clinical.consultations c
    where c.tenant_id = p_tenant_id and c.patient_id = p_patient_id and not c.is_deleted
      and identity.can_access_branch(p_tenant_id, c.branch_id)), '[]'::jsonb);
end;
$$;

-- Print payload. A draft is never printable (55000); the UI shows drafts with a DRAFT watermark only.
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
    'doctor', (select jsonb_build_object('name', p.display_name, 'registrationNumber', p.registration_number,
                                         'council', p.council_name, 'qualifications', p.qualifications)
               from appointment.practitioners p where p.id = v.practitioner_id),
    'patient', (select jsonb_build_object('mrn', p.mrn, 'name', btrim(p.first_name || ' ' || coalesce(p.last_name, '')),
                                          'dateOfBirth', p.date_of_birth, 'sex', p.sex)
                from patient.patients p where p.id = v.patient_id));
end;
$$;

revoke all on all functions in schema clinical from public, anon, authenticated;
grant execute on function
  clinical.start_consultation(uuid, uuid, uuid),
  clinical.get_consultation(uuid, uuid),
  clinical.save_consultation(uuid, uuid, integer, jsonb),
  clinical.finalize_consultation(uuid, uuid, integer),
  clinical.revise_consultation(uuid, uuid),
  clinical.patient_consultations(uuid, uuid),
  clinical.consultation_print(uuid, uuid)
  to hms_svc_scheduling, hms_api, service_role;
