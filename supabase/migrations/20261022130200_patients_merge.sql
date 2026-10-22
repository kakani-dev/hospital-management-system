-- cross-schema: approved (merge repoints appointment rows through appointment.reassign_patient_for_merge,
-- enqueues messaging.outbox via messaging.enqueue, and checks identity.has_tenant_role.
-- No function body reads another schema's tables.)
-- Merge a duplicate chart into the one we keep. The duplicate is soft-deleted, not removed.
-- Tenant admins of that hospital only. A data pass below folds existing same-hospital
-- email / phone / ABHA duplicates into the oldest chart before the unique indexes exist.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ---------------------------------------------------------------- columns ----
alter table patient.patients
  add column merged_into_patient_id uuid,
  add column merged_at timestamptz,
  add column merged_by uuid;

alter table patient.patients
  add constraint patients_merge_consistent check (
    (merged_into_patient_id is null and merged_at is null and merged_by is null)
    or (merged_into_patient_id is not null and merged_at is not null and merged_by is not null
        and deleted_at is not null and id <> merged_into_patient_id)),
  add constraint patients_merged_into_same_tenant
    foreign key (tenant_id, merged_into_patient_id)
    references patient.patients (tenant_id, id) on delete restrict;

create index patients_merged_into_idx
  on patient.patients (tenant_id, merged_into_patient_id)
  where merged_into_patient_id is not null;

comment on column patient.patients.merged_into_patient_id is
  'Set when this chart was merged into another. The row stays (soft-deleted) so history and audit can still point at it.';
comment on column patient.patients.merged_at is 'When patient.merge_patients folded this chart into merged_into_patient_id.';
comment on column patient.patients.merged_by is 'Actor who merged this chart (auth.uid(), or audit.system_actor() during a migration).';

-- New columns are not in the column-level insert/update grants. Revoke anyway so a later
-- grant-all cannot widen them: only the definer functions write merge state.
revoke insert (merged_into_patient_id, merged_at, merged_by) on patient.patients from authenticated;
revoke update (merged_into_patient_id, merged_at, merged_by) on patient.patients from authenticated;

-- --------------------------------------- appointment patient reassignment ----
-- A pure patient_id move (merge) is not a reschedule and is not a follow-up edit.
-- The flag is transaction-local and set only by the merge functions.
create or replace function appointment.enforce_appointment_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_via_checkin boolean;
  v_via_queue   boolean;
  v_via_eod     boolean;
  v_ok          boolean;
begin
  if tg_op = 'INSERT' then
    if new.status is distinct from 'booked' then
      raise exception 'invalid_transition:new->%', new.status using errcode = '23514';
    end if;
    new.checked_in_at := null; new.started_at := null; new.completed_at := null; new.cancelled_at := null;
    perform appointment.assert_tenant_refs(new.tenant_id, new.branch_id);
    if not patient.patient_exists_v1(new.tenant_id, new.patient_id) then
      raise exception 'patient not found' using errcode = 'P0002';
    end if;
    perform appointment.assert_practitioner_bookable(new.tenant_id, new.practitioner_id);
    return new;
  end if;

  new.checked_in_at := old.checked_in_at; new.started_at := old.started_at;
  new.completed_at := old.completed_at;   new.cancelled_at := old.cancelled_at;

  if coalesce(current_setting('patient.merge', true), '') = 'on'
     and new.patient_id is distinct from old.patient_id
     and new.tenant_id is not distinct from old.tenant_id
     and new.status is not distinct from old.status
     and new.starts_at is not distinct from old.starts_at
     and new.ends_at is not distinct from old.ends_at
     and new.practitioner_id is not distinct from old.practitioner_id
     and new.branch_id is not distinct from old.branch_id
     and new.parent_appointment_id is not distinct from old.parent_appointment_id
     and new.hours_override is not distinct from old.hours_override
     and patient.patient_exists_v1(new.tenant_id, new.patient_id) then
    return new;
  end if;

  if old.status <> 'booked' and (
       new.starts_at is distinct from old.starts_at or new.ends_at is distinct from old.ends_at
       or new.practitioner_id is distinct from old.practitioner_id or new.patient_id is distinct from old.patient_id
       or new.branch_id is distinct from old.branch_id) then
    raise exception 'invalid_transition:reschedule_not_booked' using errcode = '23514';
  end if;

  if new.patient_id is distinct from old.patient_id
     and not patient.patient_exists_v1(new.tenant_id, new.patient_id) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if new.patient_id is distinct from old.patient_id and new.parent_appointment_id is not null then
    raise exception 'follow_up_patient_mismatch: a follow-up must stay with the same patient' using errcode = '22023';
  end if;

  if new.practitioner_id is distinct from old.practitioner_id then
    perform appointment.assert_practitioner_bookable(new.tenant_id, new.practitioner_id);
  end if;

  if new.status is not distinct from old.status then
    return new;
  end if;

  v_via_checkin := coalesce(current_setting('appointment.check_in', true), '') = old.id::text;
  v_via_queue   := coalesce(current_setting('appointment.queue_sync', true), '') = old.id::text;
  v_via_eod     := coalesce(current_setting('appointment.eod_close', true), '') = 'on';

  v_ok := case
    when old.status = 'booked' and new.status = 'checked_in' then v_via_checkin
    when old.status = 'booked' and new.status = 'cancelled' then true
    when old.status = 'booked' and new.status = 'no_show' then now() >= old.starts_at
    when old.status = 'checked_in' and new.status = 'no_show' then v_via_eod
    when old.status = 'checked_in' and new.status in ('in_consultation', 'cancelled') then true
    when old.status = 'in_consultation' and new.status = 'completed' then true
    when old.status = 'in_consultation' and new.status = 'cancelled' then v_via_queue
    else false
  end;
  if not v_ok then
    raise exception 'invalid_transition:%->%', old.status, new.status using errcode = '23514';
  end if;

  if new.status in ('in_consultation', 'completed') and not v_via_queue and auth.uid() is not null
     and not identity.has_tenant_role(new.tenant_id, array['tenant_admin', 'doctor', 'nurse']) then
    raise exception 'not permitted to move an appointment to %', new.status using errcode = '42501';
  end if;

  case new.status
    when 'checked_in' then new.checked_in_at := now();
    when 'in_consultation' then new.started_at := now();
    when 'completed' then new.completed_at := now();
    when 'cancelled' then new.cancelled_at := now();
    else null;
  end case;
  return new;
end;
$$;
revoke all on function appointment.enforce_appointment_transition() from public;

-- While a merge is in progress the duplicate's numbers are moving onto the survivor.
-- A third chart that shares one of those numbers is in the same duplicate set and is merged
-- in the same pass; the live unique index does not exist yet. After the pass, only one live row remains.
create or replace function patient.reject_shared_phone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(current_setting('patient.merge', true), '') = 'on' or new.is_deleted then
    return new;
  end if;
  if exists (
    select 1 from patient.patient_phones ph
    join patient.patients p on p.tenant_id = ph.tenant_id and p.id = ph.patient_id
     where ph.tenant_id = new.tenant_id
       and not ph.is_deleted
       and p.deleted_at is null
       and p.merged_into_patient_id is null
       and ph.patient_id <> new.patient_id
       and ph.id is distinct from new.id
       and patient.normalize_phone(ph.phone_e164) is not null
       and patient.normalize_phone(ph.phone_e164) = patient.normalize_phone(new.phone_e164)) then
    raise exception 'duplicate_phone: another patient in this hospital already has this phone number'
      using errcode = '23505';
  end if;
  return new;
end;
$$;
revoke all on function patient.reject_shared_phone() from public, anon, authenticated;

-- ------------------------------------------------------------- outbox type ----
alter table messaging.outbox drop constraint outbox_aggregate_type_valid;
alter table messaging.outbox add constraint outbox_aggregate_type_valid
  check (aggregate_type in ('appointment', 'queue_entry', 'tenant', 'email_message', 'patient'));

create or replace function messaging.set_outbox_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.source_service := case new.aggregate_type
    when 'appointment' then 'scheduling'
    when 'queue_entry' then 'scheduling'
    when 'tenant' then 'identity'
    when 'email_message' then 'identity'
    when 'patient' then 'patients'
  end;
  if new.source_service is null then
    raise exception 'no owning service for aggregate type %', new.aggregate_type using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function messaging.set_outbox_source() from public;

-- Owner-only. Moves appointments (parent links stay; both ends land on the survivor)
-- and queue rows. An active queue row that would collide with the survivor's active row
-- on the same branch and day is cancelled in the same statement, then repointed.
create or replace function appointment.reassign_patient_for_merge(
  p_tenant_id uuid, p_from_patient_id uuid, p_to_patient_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_set boolean := coalesce(current_setting('patient.merge', true), '') is distinct from 'on';
begin
  if p_from_patient_id = p_to_patient_id then
    return;
  end if;
  if v_set then
    perform set_config('patient.merge', 'on', true);
  end if;

  update appointment.queue_entries q
     set patient_id = p_to_patient_id,
         status = case
           when q.status in ('waiting', 'in_consultation') and exists (
             select 1 from appointment.queue_entries s
              where s.tenant_id = q.tenant_id and s.branch_id = q.branch_id and s.queue_date = q.queue_date
                and s.patient_id = p_to_patient_id and s.id <> q.id
                and s.status in ('waiting', 'in_consultation'))
           then 'cancelled' else q.status end,
         cancelled_at = case
           when q.status in ('waiting', 'in_consultation') and exists (
             select 1 from appointment.queue_entries s
              where s.tenant_id = q.tenant_id and s.branch_id = q.branch_id and s.queue_date = q.queue_date
                and s.patient_id = p_to_patient_id and s.id <> q.id
                and s.status in ('waiting', 'in_consultation'))
           then coalesce(q.cancelled_at, now()) else q.cancelled_at end
   where q.tenant_id = p_tenant_id and q.patient_id = p_from_patient_id;

  update appointment.appointments
     set patient_id = p_to_patient_id
   where tenant_id = p_tenant_id and patient_id = p_from_patient_id;

  if v_set then
    perform set_config('patient.merge', '', true);
  end if;
exception when others then
  if v_set then
    perform set_config('patient.merge', '', true);
  end if;
  raise;
end;
$$;
revoke all on function appointment.reassign_patient_for_merge(uuid, uuid, uuid) from public, anon, authenticated, service_role;
comment on function appointment.reassign_patient_for_merge(uuid, uuid, uuid) is
  'Owner-only. Repoint appointments and queue entries from one patient to another. Called by patient.merge_patients_apply.';

-- -------------------------------------------------------------- merge apply ----
-- No auth check: the migration runs with an empty JWT. patient.merge_patients is the gated wrapper.
create or replace function patient.merge_patients_apply(
  p_survivor_id uuid, p_duplicate_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sur record;
  v_dup record;
  v_sur_found boolean;
  v_dup_found boolean;
  v_email text;
  v_abha text;
  v_dob date;
  v_sex text;
  v_reason text;
  v_phone record;
  v_primary boolean;
  v_wa boolean;
begin
  v_reason := nullif(btrim(p_reason), '');
  if v_reason is null then
    raise exception 'reason is required' using errcode = '22023';
  end if;
  if length(p_reason) > 500 or length(v_reason) > 500 then
    raise exception 'reason too long (max 500)' using errcode = '22023';
  end if;
  if p_survivor_id is null or p_duplicate_id is null then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if p_survivor_id = p_duplicate_id then
    raise exception 'a chart cannot be merged into itself' using errcode = '22023';
  end if;

  -- Lock in id order so two merges cannot deadlock.
  if p_survivor_id < p_duplicate_id then
    select p.id, p.tenant_id, p.mrn, p.email, p.abha_number, p.date_of_birth, p.sex,
           p.deleted_at, p.merged_into_patient_id
      into v_sur from patient.patients p where p.id = p_survivor_id for update;
    v_sur_found := found;
    select p.id, p.tenant_id, p.mrn, p.email, p.abha_number, p.date_of_birth, p.sex,
           p.deleted_at, p.merged_into_patient_id
      into v_dup from patient.patients p where p.id = p_duplicate_id for update;
    v_dup_found := found;
  else
    select p.id, p.tenant_id, p.mrn, p.email, p.abha_number, p.date_of_birth, p.sex,
           p.deleted_at, p.merged_into_patient_id
      into v_dup from patient.patients p where p.id = p_duplicate_id for update;
    v_dup_found := found;
    select p.id, p.tenant_id, p.mrn, p.email, p.abha_number, p.date_of_birth, p.sex,
           p.deleted_at, p.merged_into_patient_id
      into v_sur from patient.patients p where p.id = p_survivor_id for update;
    v_sur_found := found;
  end if;

  if not v_sur_found or not v_dup_found or v_sur.tenant_id is distinct from v_dup.tenant_id then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if v_dup.merged_into_patient_id = p_survivor_id and v_dup.deleted_at is not null then
    raise notice 'patient.merge: % already merged into %', v_dup.mrn, v_sur.mrn;
    return;
  end if;
  if v_dup.merged_into_patient_id is not null then
    raise exception 'patient is already merged into another chart' using errcode = '22023';
  end if;
  if v_sur.deleted_at is not null or v_sur.merged_into_patient_id is not null then
    raise exception 'survivor is not a live chart' using errcode = '22023';
  end if;

  v_email := nullif(btrim(v_dup.email), '');
  v_abha := v_dup.abha_number;
  v_dob := v_dup.date_of_birth;
  v_sex := v_dup.sex;

  perform set_config('patient.merge', 'on', true);
  begin
    perform appointment.reassign_patient_for_merge(v_sur.tenant_id, p_duplicate_id, p_survivor_id);

    -- One primary and one WhatsApp flag per chart. A number the survivor already has is dropped.
    -- A distinct number that cannot keep a flag is soft-deleted (the row remains for audit).
    for v_phone in
      select id, phone_e164, is_primary, is_whatsapp
        from patient.patient_phones
       where patient_id = p_duplicate_id and not is_deleted
       order by id
       for update
    loop
      if exists (
        select 1 from patient.patient_phones s
         where s.patient_id = p_survivor_id and not s.is_deleted
           and patient.normalize_phone(s.phone_e164) is not null
           and patient.normalize_phone(s.phone_e164) = patient.normalize_phone(v_phone.phone_e164)) then
        update patient.patient_phones set is_deleted = true where id = v_phone.id;
        continue;
      end if;
      v_primary := v_phone.is_primary;
      v_wa := v_phone.is_whatsapp;
      if v_primary and exists (
        select 1 from patient.patient_phones s
         where s.patient_id = p_survivor_id and s.is_primary and not s.is_deleted) then
        v_primary := false;
      end if;
      if v_wa and exists (
        select 1 from patient.patient_phones s
         where s.patient_id = p_survivor_id and s.is_whatsapp and not s.is_deleted) then
        v_wa := false;
      end if;
      if not v_primary and not v_wa then
        update patient.patient_phones set is_deleted = true where id = v_phone.id;
      else
        update patient.patient_phones
           set patient_id = p_survivor_id, is_primary = v_primary, is_whatsapp = v_wa
         where id = v_phone.id;
      end if;
    end loop;

    -- Soft-delete before copying email / ABHA so the live unique indexes (once they exist) are free.
    update patient.patients
       set deleted_at = now(),
           deleted_by = coalesce(auth.uid(), audit.system_actor()),
           deletion_reason = v_reason,
           merged_into_patient_id = p_survivor_id,
           merged_at = now(),
           merged_by = coalesce(auth.uid(), audit.system_actor())
     where id = p_duplicate_id;

    update patient.patients s
       set email = case when nullif(btrim(s.email), '') is null then v_email else s.email end,
           abha_number = case when s.abha_number is null then v_abha else s.abha_number end,
           date_of_birth = case when s.date_of_birth is null then v_dob else s.date_of_birth end,
           sex = case when s.sex = 'unknown' and v_sex is distinct from 'unknown' then v_sex else s.sex end,
           phone = case when nullif(btrim(s.phone), '') is null then (
             select live.phone_e164 from patient.patient_phones live
              where live.patient_id = s.id and live.is_primary and not live.is_deleted
              limit 1) else s.phone end
     where s.id = p_survivor_id;

    perform messaging.enqueue(v_sur.tenant_id, 'patient', p_survivor_id, 'patient.merged', jsonb_build_object(
      'survivor_patient_id', p_survivor_id,
      'duplicate_patient_id', p_duplicate_id,
      'tenant_id', v_sur.tenant_id));

    perform set_config('patient.merge', '', true);
  exception when others then
    perform set_config('patient.merge', '', true);
    raise;
  end;
end;
$$;
revoke all on function patient.merge_patients_apply(uuid, uuid, text) from public, anon, authenticated, service_role;
comment on function patient.merge_patients_apply(uuid, uuid, text) is
  'Owner-only merge. Repoints visits, queue and phones, soft-deletes the duplicate, fills blank survivor fields, writes audit (via the row trigger) and a patient.merged outbox event. No names, emails or the reason in the payload.';

create or replace function patient.merge_patients(
  p_survivor_id uuid, p_duplicate_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sur_tenant uuid;
  v_dup_tenant uuid;
begin
  if nullif(btrim(p_reason), '') is null then
    raise exception 'reason is required' using errcode = '22023';
  end if;
  if length(p_reason) > 500 then
    raise exception 'reason too long (max 500)' using errcode = '22023';
  end if;
  if p_survivor_id is null or p_duplicate_id is null then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if p_survivor_id = p_duplicate_id then
    raise exception 'a chart cannot be merged into itself' using errcode = '22023';
  end if;

  select p.tenant_id into v_sur_tenant from patient.patients p where p.id = p_survivor_id;
  select p.tenant_id into v_dup_tenant from patient.patients p where p.id = p_duplicate_id;
  if v_sur_tenant is null or v_dup_tenant is null or v_sur_tenant is distinct from v_dup_tenant
     or v_sur_tenant not in (select identity.current_tenant_ids()) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_sur_tenant, array['tenant_admin']) then
    raise exception 'only tenant admins can merge patients' using errcode = '42501';
  end if;

  perform patient.merge_patients_apply(p_survivor_id, p_duplicate_id, btrim(p_reason));
end;
$$;
revoke all on function patient.merge_patients(uuid, uuid, text) from public, anon;
grant execute on function patient.merge_patients(uuid, uuid, text) to authenticated, service_role;
comment on function patient.merge_patients(uuid, uuid, text) is
  'Tenant admin of this hospital folds the duplicate chart into the survivor. Cross-tenant and unknown ids are P0002. A second call for the same pair is a no-op.';

-- ------------------------------------------------------- one-off duplicates ----
-- Idempotent: a chart already merged is not live, so a second run finds nothing.
-- Survivor is the oldest chart in the component (created_on, created_at, mrn, id), not the smallest id.
create or replace function patient.merge_duplicate_charts()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_guard integer := 0;
  v_survivor uuid;
  v_survivor_mrn text;
  r record;
  d record;
begin
  create temporary table if not exists merge_chart_node (
    tenant_id uuid not null,
    patient_id uuid not null,
    created_on timestamptz not null,
    created_at timestamptz not null,
    mrn text not null,
    label uuid not null,
    primary key (patient_id)
  ) on commit drop;
  create temporary table if not exists merge_chart_edge (
    tenant_id uuid not null,
    a uuid not null,
    b uuid not null,
    primary key (a, b)
  ) on commit drop;
  truncate merge_chart_node;
  truncate merge_chart_edge;

  insert into merge_chart_node (tenant_id, patient_id, created_on, created_at, mrn, label)
  select p.tenant_id, p.id, p.created_on, p.created_at, p.mrn, p.id
    from patient.patients p
   where p.deleted_at is null and p.merged_into_patient_id is null;

  insert into merge_chart_edge (tenant_id, a, b)
  select p1.tenant_id, p1.id, p2.id
    from patient.patients p1
    join patient.patients p2
      on p1.tenant_id = p2.tenant_id and p1.id < p2.id
     and p1.deleted_at is null and p2.deleted_at is null
     and p1.merged_into_patient_id is null and p2.merged_into_patient_id is null
     and nullif(btrim(p1.email), '') is not null
     and lower(btrim(p1.email)) = lower(btrim(p2.email))
  on conflict do nothing;

  insert into merge_chart_edge (tenant_id, a, b)
  select n1.tenant_id, least(n1.patient_id, n2.patient_id), greatest(n1.patient_id, n2.patient_id)
    from (
      select p.tenant_id, p.id as patient_id, patient.normalize_phone(p.phone) as num
        from patient.patients p
       where p.deleted_at is null and p.merged_into_patient_id is null
         and patient.normalize_phone(p.phone) is not null
      union
      select ph.tenant_id, ph.patient_id, patient.normalize_phone(ph.phone_e164)
        from patient.patient_phones ph
        join patient.patients p on p.tenant_id = ph.tenant_id and p.id = ph.patient_id
       where not ph.is_deleted and p.deleted_at is null and p.merged_into_patient_id is null
         and patient.normalize_phone(ph.phone_e164) is not null
    ) n1
    join (
      select p.tenant_id, p.id as patient_id, patient.normalize_phone(p.phone) as num
        from patient.patients p
       where p.deleted_at is null and p.merged_into_patient_id is null
         and patient.normalize_phone(p.phone) is not null
      union
      select ph.tenant_id, ph.patient_id, patient.normalize_phone(ph.phone_e164)
        from patient.patient_phones ph
        join patient.patients p on p.tenant_id = ph.tenant_id and p.id = ph.patient_id
       where not ph.is_deleted and p.deleted_at is null and p.merged_into_patient_id is null
         and patient.normalize_phone(ph.phone_e164) is not null
    ) n2
      on n1.tenant_id = n2.tenant_id and n1.num = n2.num and n1.patient_id < n2.patient_id
  on conflict do nothing;

  insert into merge_chart_edge (tenant_id, a, b)
  select a.tenant_id, a.patient_id, b.patient_id
    from (
      select p.tenant_id, p.id as patient_id, regexp_replace(p.abha_number, '[^0-9]', '', 'g') as digits
        from patient.patients p
       where p.deleted_at is null and p.merged_into_patient_id is null and p.abha_number is not null
    ) a
    join (
      select p.tenant_id, p.id as patient_id, regexp_replace(p.abha_number, '[^0-9]', '', 'g') as digits
        from patient.patients p
       where p.deleted_at is null and p.merged_into_patient_id is null and p.abha_number is not null
    ) b
      on a.tenant_id = b.tenant_id and a.patient_id < b.patient_id
     and length(a.digits) = 14 and a.digits = b.digits
  on conflict do nothing;

  loop
    update merge_chart_node n
       set label = s.min_label
      from (
        select n2.patient_id, (array_agg(nb.label order by nb.label))[1] as min_label
          from merge_chart_node n2
          join merge_chart_edge e
            on e.tenant_id = n2.tenant_id and (e.a = n2.patient_id or e.b = n2.patient_id)
          join merge_chart_node nb
            on nb.patient_id = case when e.a = n2.patient_id then e.b else e.a end
         group by n2.patient_id
      ) s
     where n.patient_id = s.patient_id
       and s.min_label < n.label;
    exit when not found;
    v_guard := v_guard + 1;
    if v_guard > 1000 then
      raise exception 'patient merge did not converge' using errcode = '55000';
    end if;
  end loop;

  for r in
    select distinct n.tenant_id, n.label
      from merge_chart_node n
     where exists (
       select 1 from merge_chart_node o
        where o.tenant_id = n.tenant_id and o.label = n.label and o.patient_id <> n.patient_id)
  loop
    select patient_id, mrn into v_survivor, v_survivor_mrn
      from merge_chart_node
     where tenant_id = r.tenant_id and label = r.label
     order by created_on, created_at, mrn, patient_id
     limit 1;

    for d in
      select patient_id, mrn
        from merge_chart_node
       where tenant_id = r.tenant_id and label = r.label and patient_id <> v_survivor
       order by created_on, created_at, mrn, patient_id
    loop
      perform patient.merge_patients_apply(
        v_survivor, d.patient_id, 'Duplicate chart merged before live email, phone and ABHA indexes');
      raise notice 'patient.merge: % into %', d.mrn, v_survivor_mrn;
      v_count := v_count + 1;
    end loop;
  end loop;

  if v_count = 0 then
    raise notice 'patient.merge: no duplicate charts';
  else
    raise notice 'patient.merge: merged % chart(s)', v_count;
  end if;
  return v_count;
end;
$$;
revoke all on function patient.merge_duplicate_charts() from public, anon, authenticated, service_role;
comment on function patient.merge_duplicate_charts() is
  'Fold every live same-hospital duplicate set (email, phone or ABHA) into its oldest chart. Idempotent. Reports each merge with RAISE NOTICE.';

-- A merged chart must stay deleted. Restoring it would put the shared email, phone or ABHA back.
create or replace function patient.restore_patient(p_patient_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p record;
begin
  select p.id, p.tenant_id, p.is_deleted, p.merged_into_patient_id into v_p
  from patient.patients p where p.id = p_patient_id
  for update;

  if v_p.id is null or v_p.tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_p.tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can restore patients' using errcode = '42501';
  end if;
  if v_p.merged_into_patient_id is not null then
    raise exception 'merged patient cannot be restored' using errcode = '55000';
  end if;
  if not v_p.is_deleted then
    raise exception 'patient is not deleted' using errcode = 'P0002';
  end if;

  update patient.patients
     set deleted_at = null, deleted_by = null, deletion_reason = null
   where id = v_p.id;
end;
$$;

-- Runs before 20261022130300 creates the live unique indexes. On a database that already
-- has duplicate charts this is what makes those indexes succeed. Empty databases notice and return.
do $$ begin perform patient.merge_duplicate_charts(); end $$;
