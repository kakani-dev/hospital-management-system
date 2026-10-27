-- cross-schema: approved (clinical schema owned by scheduling per ADR 0003; reads appointment.queue_entries
-- and patient.patients.deleted_at inside security-definer functions, RLS helpers identity.current_tenant_ids /
-- can_access_branch / has_tenant_permission, audit.* trigger functions, and adds the clinical.vitals
-- permission to identity.role_permissions.)
-- #104: triage vitals per visit. Append-only (a correction is a new reading). Hard limits reject impossible
-- values (22023); values outside the normal adult range are stored and flagged. The tenant id always comes
-- from the server session and is checked against the caller's memberships.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

insert into identity.role_permissions (role, permission) values
  ('nurse', 'clinical.vitals'),
  ('doctor', 'clinical.vitals'),
  ('tenant_admin', 'clinical.vitals')
on conflict do nothing;

create table clinical.vitals (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references identity.tenants (id) on delete restrict,
  branch_id        uuid not null,
  patient_id       uuid not null,
  queue_entry_id   uuid not null,
  client_id        uuid,
  recorded_on      timestamptz not null default now(),
  systolic_mmhg    smallint,
  diastolic_mmhg   smallint,
  pulse_bpm        smallint,
  temperature_c    numeric(4,1),
  weight_kg        numeric(5,1),
  height_cm        numeric(5,1),
  spo2_pct         smallint,
  resp_rate        smallint,
  note             text,
  created_on       timestamptz not null default now(),
  created_by       uuid not null,
  updated_on       timestamptz not null default now(),
  updated_by       uuid not null,
  is_deleted       boolean not null default false,
  constraint vitals_tenant_id_id_key unique (tenant_id, id),
  constraint vitals_branch_same_tenant
    foreign key (tenant_id, branch_id) references identity.branches (tenant_id, id) on delete restrict,
  constraint vitals_patient_same_tenant
    foreign key (tenant_id, patient_id) references patient.patients (tenant_id, id) on delete restrict,
  constraint vitals_queue_same_tenant
    foreign key (tenant_id, queue_entry_id) references appointment.queue_entries (tenant_id, id) on delete restrict,
  constraint vitals_bp check ((systolic_mmhg is null) = (diastolic_mmhg is null)
    and (systolic_mmhg is null or (systolic_mmhg between 50 and 300 and diastolic_mmhg between 20 and 200
                                   and diastolic_mmhg < systolic_mmhg))),
  constraint vitals_pulse check (pulse_bpm is null or pulse_bpm between 20 and 250),
  constraint vitals_temperature check (temperature_c is null or temperature_c between 30 and 45),
  constraint vitals_weight check (weight_kg is null or weight_kg between 0.3 and 400),
  constraint vitals_height check (height_cm is null or height_cm between 20 and 250),
  constraint vitals_spo2 check (spo2_pct is null or spo2_pct between 0 and 100),
  constraint vitals_resp check (resp_rate is null or resp_rate between 4 and 80),
  constraint vitals_something check (num_nonnulls(systolic_mmhg, pulse_bpm, temperature_c, weight_kg, height_cm, spo2_pct, resp_rate) > 0),
  constraint vitals_note_len check (coalesce(length(note), 0) <= 500)
);
create unique index vitals_client_id on clinical.vitals (tenant_id, client_id) where client_id is not null;
create index vitals_patient_idx on clinical.vitals (tenant_id, patient_id, recorded_on desc) where not is_deleted;
create index vitals_visit_idx on clinical.vitals (tenant_id, queue_entry_id, recorded_on desc) where not is_deleted;
comment on table clinical.vitals is
  'Triage vitals for one visit (queue entry). Append-only; a correction is a new reading. Times are UTC. client_id is the double-submit key.';

create trigger vitals_audit_columns before insert or update on clinical.vitals
  for each row execute function audit.stamp_audit_columns();
create trigger vitals_tenant_immutable before update on clinical.vitals
  for each row execute function audit.prevent_tenant_change();
create trigger vitals_audit_log after insert or update or delete on clinical.vitals
  for each row execute function audit.log_row_change();

alter table clinical.vitals enable row level security;
revoke all on clinical.vitals from public, anon, authenticated;
grant select on clinical.vitals to hms_svc_scheduling, hms_api;
create policy vitals_read on clinical.vitals for select to hms_svc_scheduling, hms_api
  using (tenant_id in (select identity.current_tenant_ids())
         and identity.can_access_branch(tenant_id, branch_id)
         and identity.has_tenant_permission(tenant_id, 'clinical.view'));

-- Normal adult ranges -> flags. Stored values are never altered; the flag is derived on read.
create or replace function clinical.vitals_flags(v clinical.vitals)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_agg(f) filter (where f is not null), '[]'::jsonb)
  from (values
    (case when v.systolic_mmhg >= 140 then jsonb_build_object('field', 'systolic', 'level', 'high')
          when v.systolic_mmhg < 90 then jsonb_build_object('field', 'systolic', 'level', 'low') end),
    (case when v.diastolic_mmhg >= 90 then jsonb_build_object('field', 'diastolic', 'level', 'high')
          when v.diastolic_mmhg < 60 then jsonb_build_object('field', 'diastolic', 'level', 'low') end),
    (case when v.pulse_bpm > 100 then jsonb_build_object('field', 'pulse', 'level', 'high')
          when v.pulse_bpm < 60 then jsonb_build_object('field', 'pulse', 'level', 'low') end),
    (case when v.temperature_c >= 38 then jsonb_build_object('field', 'temperature', 'level', 'high')
          when v.temperature_c < 35 then jsonb_build_object('field', 'temperature', 'level', 'low') end),
    (case when v.spo2_pct < 90 then jsonb_build_object('field', 'spo2', 'level', 'critical')
          when v.spo2_pct < 95 then jsonb_build_object('field', 'spo2', 'level', 'low') end),
    (case when v.resp_rate > 20 then jsonb_build_object('field', 'respRate', 'level', 'high')
          when v.resp_rate < 12 then jsonb_build_object('field', 'respRate', 'level', 'low') end)
  ) as t(f)
$$;

create or replace function clinical.vitals_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', v.id, 'patientId', v.patient_id, 'queueEntryId', v.queue_entry_id, 'branchId', v.branch_id,
    'recordedOn', v.recorded_on, 'recordedBy', v.created_by,
    'systolic', v.systolic_mmhg, 'diastolic', v.diastolic_mmhg, 'pulse', v.pulse_bpm,
    'temperatureC', v.temperature_c, 'weightKg', v.weight_kg, 'heightCm', v.height_cm,
    'bmi', case when v.weight_kg is not null and v.height_cm is not null
                then round(v.weight_kg / ((v.height_cm / 100.0) ^ 2), 1) end,
    'spo2', v.spo2_pct, 'respRate', v.resp_rate, 'note', v.note,
    'flags', clinical.vitals_flags(v))
  from clinical.vitals v where v.id = p_id
$$;

-- Number parsing: missing/blank -> null; not a number -> 22023 with the field name.
create or replace function clinical.vitals_num(p_body jsonb, p_key text)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_text text := nullif(btrim(p_body ->> p_key), '');
begin
  if v_text is null then
    return null;
  end if;
  begin
    return v_text::numeric;
  exception when others then
    raise exception '% must be a number', p_key using errcode = '22023';
  end;
end;
$$;

create or replace function clinical.record_vitals(p_tenant_id uuid, p_queue_entry_id uuid, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q record;
  v_id uuid;
  v_client uuid;
  v_sys numeric := clinical.vitals_num(p_body, 'systolic');
  v_dia numeric := clinical.vitals_num(p_body, 'diastolic');
  v_pulse numeric := clinical.vitals_num(p_body, 'pulse');
  v_temp numeric := clinical.vitals_num(p_body, 'temperatureC');
  v_wt numeric := clinical.vitals_num(p_body, 'weightKg');
  v_ht numeric := clinical.vitals_num(p_body, 'heightCm');
  v_spo2 numeric := clinical.vitals_num(p_body, 'spo2');
  v_rr numeric := clinical.vitals_num(p_body, 'respRate');
begin
  perform clinical.assert_tenant(p_tenant_id);
  if not identity.has_tenant_permission(p_tenant_id, 'clinical.vitals') then
    raise exception 'not permitted to record vitals' using errcode = '42501';
  end if;
  if p_body is null or jsonb_typeof(p_body) <> 'object' then
    raise exception 'body must be a JSON object' using errcode = '22023';
  end if;
  begin
    v_client := nullif(p_body ->> 'clientId', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'clientId must be a uuid' using errcode = '22023';
  end;
  if v_client is not null then
    select v.id into v_id from clinical.vitals v where v.tenant_id = p_tenant_id and v.client_id = v_client;
    if v_id is not null then
      return clinical.vitals_json(v_id);
    end if;
  end if;

  select q.id, q.branch_id, q.patient_id, q.status into v_q
  from appointment.queue_entries q where q.id = p_queue_entry_id and q.tenant_id = p_tenant_id;
  if v_q.id is null then
    raise exception 'queue entry not found' using errcode = 'P0002';
  end if;
  if not identity.can_access_branch(p_tenant_id, v_q.branch_id) then
    raise exception 'not permitted for this branch' using errcode = '42501';
  end if;
  if v_q.status in ('cancelled', 'no_show', 'expired') then
    raise exception 'vitals cannot be recorded for a % visit', replace(v_q.status, '_', '-') using errcode = '55000';
  end if;
  if exists (select 1 from patient.patients p where p.id = v_q.patient_id and p.deleted_at is not null) then
    raise exception 'the patient record is deleted' using errcode = '55000';
  end if;

  if num_nonnulls(v_sys, v_dia, v_pulse, v_temp, v_wt, v_ht, v_spo2, v_rr) = 0 then
    raise exception 'enter at least one vital sign' using errcode = '22023';
  end if;
  if (v_sys is null) <> (v_dia is null) then
    raise exception 'blood pressure needs both systolic and diastolic' using errcode = '22023';
  end if;
  if v_sys is not null and (v_sys <> trunc(v_sys) or v_sys not between 50 and 300) then
    raise exception 'systolic must be 50 to 300 mmHg' using errcode = '22023';
  end if;
  if v_dia is not null and (v_dia <> trunc(v_dia) or v_dia not between 20 and 200) then
    raise exception 'diastolic must be 20 to 200 mmHg' using errcode = '22023';
  end if;
  if v_sys is not null and v_dia >= v_sys then
    raise exception 'diastolic must be lower than systolic' using errcode = '22023';
  end if;
  if v_pulse is not null and (v_pulse <> trunc(v_pulse) or v_pulse not between 20 and 250) then
    raise exception 'pulse must be 20 to 250 per minute' using errcode = '22023';
  end if;
  if v_temp is not null and v_temp not between 30 and 45 then
    raise exception 'temperature must be 30 to 45 °C' using errcode = '22023';
  end if;
  if v_wt is not null and v_wt not between 0.3 and 400 then
    raise exception 'weight must be 0.3 to 400 kg' using errcode = '22023';
  end if;
  if v_ht is not null and v_ht not between 20 and 250 then
    raise exception 'height must be 20 to 250 cm' using errcode = '22023';
  end if;
  if v_spo2 is not null and (v_spo2 <> trunc(v_spo2) or v_spo2 not between 0 and 100) then
    raise exception 'SpO2 must be a whole number from 0 to 100' using errcode = '22023';
  end if;
  if v_rr is not null and (v_rr <> trunc(v_rr) or v_rr not between 4 and 80) then
    raise exception 'respiratory rate must be 4 to 80 per minute' using errcode = '22023';
  end if;
  if length(coalesce(p_body ->> 'note', '')) > 500 then
    raise exception 'note must be at most 500 characters' using errcode = '22023';
  end if;

  begin
    insert into clinical.vitals (
      tenant_id, branch_id, patient_id, queue_entry_id, client_id, systolic_mmhg, diastolic_mmhg, pulse_bpm,
      temperature_c, weight_kg, height_cm, spo2_pct, resp_rate, note)
    values (
      p_tenant_id, v_q.branch_id, v_q.patient_id, v_q.id, v_client, v_sys, v_dia, v_pulse,
      round(v_temp, 1), round(v_wt, 1), round(v_ht, 1), v_spo2, v_rr, nullif(btrim(p_body ->> 'note'), ''))
    returning id into v_id;
  exception when unique_violation then
    -- Concurrent double-submit with the same clientId: return the row that won.
    select v.id into v_id from clinical.vitals v where v.tenant_id = p_tenant_id and v.client_id = v_client;
  end;
  return clinical.vitals_json(v_id);
end;
$$;

-- History: newest first. patientId or queueEntryId (exactly one).
create or replace function clinical.list_vitals(p_tenant_id uuid, p_patient_id uuid, p_queue_entry_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform clinical.assert_tenant(p_tenant_id);
  if not identity.has_tenant_permission(p_tenant_id, 'clinical.view') then
    raise exception 'not permitted to view vitals' using errcode = '42501';
  end if;
  if (p_patient_id is null) = (p_queue_entry_id is null) then
    raise exception 'pass exactly one of patientId or queueEntryId' using errcode = '22023';
  end if;
  return coalesce((
    select jsonb_agg(clinical.vitals_json(v.id) order by v.recorded_on desc, v.id)
    from (select v.id, v.recorded_on from clinical.vitals v
          where v.tenant_id = p_tenant_id and not v.is_deleted
            and (p_patient_id is null or v.patient_id = p_patient_id)
            and (p_queue_entry_id is null or v.queue_entry_id = p_queue_entry_id)
            and identity.can_access_branch(p_tenant_id, v.branch_id)
          order by v.recorded_on desc limit 200) v), '[]'::jsonb);
end;
$$;

revoke all on function clinical.vitals_flags(clinical.vitals), clinical.vitals_json(uuid), clinical.vitals_num(jsonb, text),
  clinical.record_vitals(uuid, uuid, jsonb), clinical.list_vitals(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function clinical.record_vitals(uuid, uuid, jsonb), clinical.list_vitals(uuid, uuid, uuid)
  to hms_svc_scheduling, hms_api, service_role;
