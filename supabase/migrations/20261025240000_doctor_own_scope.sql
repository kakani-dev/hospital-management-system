-- cross-schema: approved (appointment policies call identity.has_role_at_branch;
-- the patient select policy calls appointment.caller_sees_patient_v1)
-- A doctor sees and acts only on appointments, queue entries and charts of a practitioner
-- linked to their login. A broader role at that branch (admin, nurse, reception, billing)
-- still sees the branch. An unlinked practitioner is not "own".
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function identity.has_role_at_branch(p_tenant_id uuid, p_branch_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from identity.memberships m
    join identity.tenants t on t.id = m.tenant_id
    where m.user_id = auth.uid()
      and m.tenant_id = p_tenant_id
      and m.status = 'active'
      and not m.is_deleted
      and (m.branch_id is null or m.branch_id = p_branch_id)
      and (m.branch_id is null or exists (
            select 1 from identity.branches mb where mb.id = m.branch_id and not mb.is_deleted))
      and t.status = 'active'
      and not t.is_deleted
      and m.role = any (p_roles)
      and (identity.active_tenant_claim() is null or m.tenant_id = identity.active_tenant_claim())
  )
$$;
revoke all on function identity.has_role_at_branch(uuid, uuid, text[]) from public, anon;
grant execute on function identity.has_role_at_branch(uuid, uuid, text[])
  to authenticated, hms_svc_patients, hms_svc_scheduling;
comment on function identity.has_role_at_branch(uuid, uuid, text[]) is
  'True when the caller holds one of the roles at this branch (a null membership branch covers every branch).';

create or replace function appointment.caller_practitioner_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.id
  from appointment.practitioners p
  where p.user_id = auth.uid()
    and not p.is_deleted
$$;
revoke all on function appointment.caller_practitioner_ids() from public, anon;
grant execute on function appointment.caller_practitioner_ids()
  to authenticated, hms_svc_patients, hms_svc_scheduling;
comment on function appointment.caller_practitioner_ids() is
  'Practitioners linked to the caller. Empty when the login is not linked: the doctor sees nothing.';

-- cross-schema: approved (patient RLS calls this; it reads appointment rows)
create or replace function appointment.caller_sees_patient_v1(p_tenant_id uuid, p_patient_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from appointment.appointments a
     where a.tenant_id = p_tenant_id and a.patient_id = p_patient_id and not a.is_deleted
       and a.practitioner_id in (select appointment.caller_practitioner_ids())
  ) or exists (
    select 1 from appointment.queue_entries q
     where q.tenant_id = p_tenant_id and q.patient_id = p_patient_id and not q.is_deleted
       and q.practitioner_id in (select appointment.caller_practitioner_ids())
  )
$$;
revoke all on function appointment.caller_sees_patient_v1(uuid, uuid) from public, anon;
grant execute on function appointment.caller_sees_patient_v1(uuid, uuid)
  to authenticated, hms_svc_patients, hms_svc_scheduling;
comment on function appointment.caller_sees_patient_v1(uuid, uuid) is
  'True when the caller is the practitioner on a visit or queue entry for this patient in this hospital.';

-- Doctors may follow up only their own visit, booked as themselves.
create or replace function appointment.set_queue_status(p_queue_entry_id uuid, p_status text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_q record;
  v_ok boolean;
  v_appt_status text;
begin
  select q.id, q.tenant_id, q.branch_id, q.status, q.appointment_id, q.practitioner_id into v_q
  from appointment.queue_entries q where q.id = p_queue_entry_id
  for update;

  if v_q.id is null or v_q.tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'queue entry not found' using errcode = 'P0002';
  end if;

  if not identity.can_access_branch(v_q.tenant_id, v_q.branch_id) then
    raise exception 'not permitted for this branch' using errcode = '42501';
  end if;
  if not (identity.has_tenant_role(v_q.tenant_id, array['tenant_admin', 'receptionist', 'nurse'])
          or (p_status in ('in_consultation', 'done') and identity.has_tenant_role(v_q.tenant_id, array['doctor']))) then
    raise exception 'not permitted to set queue status %', p_status using errcode = '42501';
  end if;
  -- A doctor who is not also front desk may call only the practitioner linked to their login.
  if identity.has_tenant_role(v_q.tenant_id, array['doctor'])
     and not identity.has_tenant_role(v_q.tenant_id, array['tenant_admin', 'receptionist', 'nurse'])
     and not exists (
       select 1 from appointment.practitioners p
        where p.tenant_id = v_q.tenant_id and p.id = v_q.practitioner_id
          and p.user_id = auth.uid() and not p.is_deleted) then
    raise exception 'not permitted to set queue status %', p_status using errcode = '42501';
  end if;

  v_ok := case
    when v_q.status = 'waiting' and p_status in ('in_consultation', 'cancelled') then true
    when v_q.status = 'in_consultation' and p_status in ('done', 'cancelled') then true
    else false
  end;
  if not v_ok then
    raise exception 'invalid_transition:%->%', v_q.status, coalesce(p_status, 'null') using errcode = '23514';
  end if;

  update appointment.queue_entries q
     set status = p_status,
         called_at = case when p_status = 'in_consultation' then now() else q.called_at end,
         completed_at = case when p_status = 'done' then now() else q.completed_at end,
         cancelled_at = case when p_status = 'cancelled' then now() else q.cancelled_at end
   where q.id = v_q.id;

  if v_q.appointment_id is not null then
    v_appt_status := case p_status when 'in_consultation' then 'in_consultation'
                                   when 'done' then 'completed'
                                   when 'cancelled' then 'cancelled' end;
    perform set_config('appointment.queue_sync', v_q.appointment_id::text, true);
    update appointment.appointments a set status = v_appt_status
     where a.id = v_q.appointment_id and a.status is distinct from v_appt_status;
    perform set_config('appointment.queue_sync', '', true);
  end if;
end;
$$;

-- Keep the roles already on each policy (authenticated plus hms_svc_*).
do $pol$
declare
  v_appt_select text;
  v_appt_insert text;
  v_appt_update text;
  v_queue_select text;
  v_patient_select text;
begin
  select string_agg(quote_ident(rr.rolname), ', ' order by rr.rolname) into v_appt_select
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_roles rr on rr.oid = any (pol.polroles)
   where n.nspname = 'appointment' and c.relname = 'appointments' and pol.polname = 'appointments_select_registry_roles';
  select string_agg(quote_ident(rr.rolname), ', ' order by rr.rolname) into v_appt_insert
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_roles rr on rr.oid = any (pol.polroles)
   where n.nspname = 'appointment' and c.relname = 'appointments' and pol.polname = 'appointments_insert_writers';
  select string_agg(quote_ident(rr.rolname), ', ' order by rr.rolname) into v_appt_update
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_roles rr on rr.oid = any (pol.polroles)
   where n.nspname = 'appointment' and c.relname = 'appointments' and pol.polname = 'appointments_update_writers';
  select string_agg(quote_ident(rr.rolname), ', ' order by rr.rolname) into v_queue_select
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_roles rr on rr.oid = any (pol.polroles)
   where n.nspname = 'appointment' and c.relname = 'queue_entries' and pol.polname = 'queue_entries_select_branch';
  select string_agg(quote_ident(rr.rolname), ', ' order by rr.rolname) into v_patient_select
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_roles rr on rr.oid = any (pol.polroles)
   where n.nspname = 'patient' and c.relname = 'patients' and pol.polname = 'patients_select_registry_roles';

  if v_appt_select is null or v_appt_insert is null or v_appt_update is null
     or v_queue_select is null or v_patient_select is null then
    raise exception 'doctor scope migration: a policy to replace is missing';
  end if;

  execute 'drop policy appointments_select_registry_roles on appointment.appointments';
  execute format($f$
    create policy appointments_select_registry_roles on appointment.appointments
      for select to %s
      using (identity.can_access_branch(tenant_id, branch_id)
             and (identity.has_role_at_branch(tenant_id, branch_id, array['tenant_admin', 'nurse', 'receptionist', 'billing'])
                  or (identity.has_role_at_branch(tenant_id, branch_id, array['doctor'])
                      and practitioner_id in (select appointment.caller_practitioner_ids()))))
  $f$, v_appt_select);

  execute 'drop policy appointments_insert_writers on appointment.appointments';
  execute format($f$
    create policy appointments_insert_writers on appointment.appointments
      for insert to %s
      with check (identity.can_access_branch(tenant_id, branch_id)
                  and (identity.has_tenant_permission(tenant_id, 'appointments.book')
                       or (identity.has_tenant_permission(tenant_id, 'appointments.book_followup_own')
                           and parent_appointment_id is not null
                           and appointment.is_own_followup_parent(tenant_id, parent_appointment_id)
                           and practitioner_id in (select appointment.caller_practitioner_ids()))))
  $f$, v_appt_insert);

  execute 'drop policy appointments_update_writers on appointment.appointments';
  execute format($f$
    create policy appointments_update_writers on appointment.appointments
      for update to %s
      using (identity.can_access_branch(tenant_id, branch_id)
             and (identity.has_tenant_permission(tenant_id, 'appointments.reschedule')
                  or identity.has_tenant_permission(tenant_id, 'appointments.cancel')
                  or identity.has_tenant_permission(tenant_id, 'appointments.no_show')
                  or (identity.has_tenant_permission(tenant_id, 'appointments.no_show_own')
                      and practitioner_id in (select appointment.caller_practitioner_ids()))))
      with check (identity.can_access_branch(tenant_id, branch_id)
                  and (identity.has_tenant_permission(tenant_id, 'appointments.reschedule')
                       or identity.has_tenant_permission(tenant_id, 'appointments.cancel')
                       or identity.has_tenant_permission(tenant_id, 'appointments.no_show')
                       or (identity.has_tenant_permission(tenant_id, 'appointments.no_show_own')
                           and practitioner_id in (select appointment.caller_practitioner_ids()))))
  $f$, v_appt_update);

  execute 'drop policy queue_entries_select_branch on appointment.queue_entries';
  execute format($f$
    create policy queue_entries_select_branch on appointment.queue_entries
      for select to %s
      using (identity.can_access_branch(tenant_id, branch_id)
             and (identity.has_role_at_branch(tenant_id, branch_id, array['tenant_admin', 'nurse', 'receptionist', 'billing'])
                  or (identity.has_role_at_branch(tenant_id, branch_id, array['doctor'])
                      and practitioner_id in (select appointment.caller_practitioner_ids()))))
  $f$, v_queue_select);

  execute 'drop policy patients_select_registry_roles on patient.patients';
  execute format($f$
    create policy patients_select_registry_roles on patient.patients
      for select to %s
      using ((identity.has_tenant_role(tenant_id, array['tenant_admin', 'nurse', 'receptionist', 'billing'])
              or (identity.has_tenant_role(tenant_id, array['doctor'])
                  and appointment.caller_sees_patient_v1(tenant_id, id)))
             and (not is_deleted or identity.has_tenant_role(tenant_id, array['tenant_admin'])))
  $f$, v_patient_select);
end
$pol$;

comment on policy appointments_select_registry_roles on appointment.appointments is
  'Branch staff see the branch calendar. A doctor sees only visits of the practitioner linked to their login.';
comment on policy appointments_insert_writers on appointment.appointments is
  'Book at an accessible branch, or (doctors) a follow-up of their own visit as themselves.';
comment on policy queue_entries_select_branch on appointment.queue_entries is
  'Branch staff see the branch queue. A doctor sees only their own practitioner''s tokens.';
comment on policy patients_select_registry_roles on patient.patients is
  'Front desk and admin see the hospital chart. A doctor sees patients they have a visit or token for.';
