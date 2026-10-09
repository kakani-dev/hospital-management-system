-- =============================================================================
-- cross-schema: approved (published contracts for the microservices split; DB review B2/B4, 9 Oct 2026)
-- Microservices: the remaining PUBLISHED, VERSIONED cross-schema functions (docs/contracts/db.md).
-- Runs AFTER 20261012090000_audit_columns_and_soft_delete / 20261012090100_tenant_time_zone, which
-- already publish identity.branch_exists_v1 / branch_tenant_id_v1 / branch_time_zone_v1 /
-- branch_local_date_v1, patient.patient_exists_v1 and appointment.branch_has_open_activity_v1 /
-- queue_has_entries_v1 / patient_has_active_visits_v1. Those are NOT redefined here.
--
-- One Supabase Postgres stays; each schema has ONE owning service, and a service reads another
-- service's data ONLY through *_v1 functions, never its tables. Same rules as the audit-tz surface:
--   * SECURITY DEFINER, set search_path = '', fully-qualified names;
--   * an EXPLICIT tenant check (tenant in identity.current_tenant_ids()) because definer code
--     bypasses RLS, plus a role check where the data is personal;
--   * no definer views and no cross-service security_invoker views (B4);
--   * additive changes only; a breaking change ships as _v2 next to _v1.
-- Signatures are pinned by supabase/tests/20_ms_published_contracts_test.sql.
--
-- Added here:
--   identity.my_tenant_grant_v1(tenant)                       -> every service (tenant resolution)
--   patient.patient_summary_v1(tenant, ids[])                 -> scheduling (embedding, incl. deleted)
--   appointment.patient_has_open_visits_v1(tenant, patient)   -> patients (soft-delete guard)
-- Canonical names are the ones in docs/contracts/db.md (CTO decision 6). The audit-tz name
-- appointment.patient_has_active_visits_v1 stays as a DEPRECATED alias that delegates to
-- patient_has_open_visits_v1 (expand/contract: dropped once nothing calls it), and
-- patient.soft_delete_patient now calls the canonical name.
-- =============================================================================

-- ---------------------------------------------------------------- identity ----
-- The calling user's ACTIVE, non-deleted memberships in an ACTIVE, non-deleted tenant plus that
-- tenant's live branches with their EFFECTIVE zone (branch override, else the tenant zone):
--   {"memberships":[{"role","branch_id"}],"branches":[{"id","timezone"}]}
-- NULL when the tenant is not live or the caller has no live membership in it. Definer, but scoped
-- to auth.uid() explicitly.
create or replace function identity.my_tenant_grant_v1(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when (select auth.uid()) is not null
     and exists (select 1 from identity.tenants t
                 where t.id = p_tenant_id and t.status = 'active' and not t.is_deleted)
     and exists (select 1 from identity.memberships m
                 where m.user_id = (select auth.uid()) and m.tenant_id = p_tenant_id
                   and m.status = 'active' and not m.is_deleted) then
      jsonb_build_object(
        'memberships', coalesce((
          select jsonb_agg(jsonb_build_object('role', m.role, 'branch_id', m.branch_id) order by m.role, m.branch_id)
          from identity.memberships m
          where m.user_id = (select auth.uid()) and m.tenant_id = p_tenant_id
            and m.status = 'active' and not m.is_deleted), '[]'::jsonb),
        'branches', coalesce((
          select jsonb_agg(jsonb_build_object('id', b.id, 'timezone', coalesce(b.timezone, t.time_zone)) order by b.id)
          from identity.branches b
          join identity.tenants t on t.id = b.tenant_id
          where b.tenant_id = p_tenant_id and b.is_active and not b.is_deleted), '[]'::jsonb))
  end
$$;
revoke all on function identity.my_tenant_grant_v1(uuid) from public, anon;
grant execute on function identity.my_tenant_grant_v1(uuid) to authenticated, service_role;
comment on function identity.my_tenant_grant_v1(uuid) is
  'v1 (published by identity): caller''s live memberships in the tenant + its live branches with the effective zone; null if none. Additive changes only.';

-- ----------------------------------------------------------------- patient ----
-- Patient summaries for embedding in another service's responses (scheduling: appointments and the
-- queue board). Definer with explicit checks: the tenant must be one of the caller's, and the caller
-- must hold a role that may read appointments/patients in it (otherwise: empty, the same answer as
-- "no such patients", so it cannot be used to probe). INCLUDES soft-deleted patients
-- (is_deleted = true) so appointment history keeps a name. Only the agreed columns: no phone, email
-- or DOB. At most 500 ids per call. Trusted callers without a user (service_role) skip the checks.
create or replace function patient.patient_summary_v1(p_tenant_id uuid, p_patient_ids uuid[])
returns table (id uuid, tenant_id uuid, mrn text, first_name text, last_name text, is_deleted boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_patient_ids is null or cardinality(p_patient_ids) = 0 then
    return;
  end if;
  if cardinality(p_patient_ids) > 500 then
    raise exception 'at most 500 patient ids per call' using errcode = '22023';
  end if;
  if p_tenant_id is null
     or (auth.uid() is not null
         and (p_tenant_id not in (select identity.current_tenant_ids())
              or not identity.has_tenant_role(p_tenant_id, array['tenant_admin', 'doctor', 'nurse', 'receptionist', 'billing']))) then
    return;
  end if;

  return query
  select p.id, p.tenant_id, p.mrn, p.first_name, p.last_name, p.is_deleted
  from patient.patients p
  where p.tenant_id = p_tenant_id and p.id = any (p_patient_ids);
end;
$$;
revoke all on function patient.patient_summary_v1(uuid, uuid[]) from public, anon;
grant execute on function patient.patient_summary_v1(uuid, uuid[]) to authenticated, service_role;
comment on function patient.patient_summary_v1(uuid, uuid[]) is
  'v1 (published by patients): id, tenant_id, mrn, first_name, last_name, is_deleted for <=500 ids in one of the caller''s tenants (registry/appointment roles); includes soft-deleted patients. Additive changes only.';

-- ------------------------------------------------------------- appointment ----
-- Canonical name (docs/contracts/db.md). Open appointment (booked / checked_in / in_consultation) or
-- active queue entry (waiting / in_consultation) for the patient? Same tenant check as the rest of
-- the v1 surface: a signed-in caller must be a member of p_tenant_id, else P0002 (404-not-403).
create or replace function appointment.patient_has_open_visits_v1(p_tenant_id uuid, p_patient_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  return exists (select 1 from appointment.appointments a
                 where a.tenant_id = p_tenant_id and a.patient_id = p_patient_id
                   and a.status in ('booked', 'checked_in', 'in_consultation'))
      or exists (select 1 from appointment.queue_entries q
                 where q.tenant_id = p_tenant_id and q.patient_id = p_patient_id
                   and q.status in ('waiting', 'in_consultation'));
end;
$$;
revoke all on function appointment.patient_has_open_visits_v1(uuid, uuid) from public, anon;
grant execute on function appointment.patient_has_open_visits_v1(uuid, uuid) to authenticated, service_role;
comment on function appointment.patient_has_open_visits_v1(uuid, uuid) is
  'v1 (published by scheduling): true when the patient has open appointments or active queue entries.';

-- DEPRECATED alias (audit-tz name). Same signature and grants; delegates so the two can never drift.
create or replace function appointment.patient_has_active_visits_v1(p_tenant_id uuid, p_patient_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return appointment.patient_has_open_visits_v1(p_tenant_id, p_patient_id);
end;
$$;
comment on function appointment.patient_has_active_visits_v1(uuid, uuid) is
  'DEPRECATED v1 alias of appointment.patient_has_open_visits_v1 (canonical name, docs/contracts/db.md). Dropped by a later contract migration.';

-- patient.soft_delete_patient: the audit-tz body, unchanged except that the open-visit guard calls
-- the canonical published name. CREATE OR REPLACE keeps the grants.
create or replace function patient.soft_delete_patient(p_patient_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p record;
begin
  if p_reason is not null and length(p_reason) > 500 then
    raise exception 'reason too long (max 500)' using errcode = '22023';
  end if;

  select p.id, p.tenant_id, p.registered_branch_id, p.is_deleted into v_p
  from patient.patients p where p.id = p_patient_id
  for update;

  if v_p.id is null or v_p.tenant_id not in (select identity.current_tenant_ids()) or v_p.is_deleted then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;

  if not identity.has_tenant_role(v_p.tenant_id, array['tenant_admin', 'receptionist'])
     or not identity.can_access_branch(v_p.tenant_id, v_p.registered_branch_id) then
    raise exception 'not permitted to delete this patient' using errcode = '42501';
  end if;

  -- Cross-schema read through the scheduling service's PUBLISHED function (no direct table access).
  if appointment.patient_has_open_visits_v1(v_p.tenant_id, v_p.id) then
    raise exception 'patient has open appointments or queue entries; cancel them first' using errcode = '55000';
  end if;

  -- is_deleted is generated from deleted_at
  update patient.patients
     set deleted_at = now(),
         deleted_by = auth.uid(),
         deletion_reason = nullif(btrim(p_reason), '')
   where id = v_p.id;
end;
$$;
