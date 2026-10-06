-- =============================================================================
-- UNAPPLIED DRAFT - NOT A MIGRATION. Do not copy into supabase/migrations as-is.
--
-- PR #1 review DB hardening that was descoped on 2026-10-06 21:20 IST (development phase;
-- only the B1 invite-consent fix shipped, in 20261008090000_membership_invite_consent.sql).
-- Kept here so it is ready for a later forward migration. Status: syntax-checked once against
-- a local scratch DB (all migrations + seed, inside a rolled-back transaction); there are NO
-- regression tests for it yet and it has not been run against the Backend test suite.
--
-- Covers review items: M1 (roles bound to branches, tenant_admin tenant-wide), M2 (audit
-- columns: actor wins, client column grants revoked), Minor 8 (FORCE RLS), Minor 10/11
-- (case-insensitive MRN uniqueness, phone/email length CHECKs), Minor 1 (hms_api trust model).
-- Hosted read-only check at 21:20 IST (project gvgomzogbzbjhlcsimrx): 0 branch-scoped
-- tenant_admin rows, 0 phone > 32, 0 email > 254, 0 case-insensitive MRN duplicate groups;
-- all 6 tables owned by postgres (rolbypassrls = true), so FORCE RLS does not affect the
-- SECURITY DEFINER helpers there.
-- =============================================================================

-- ---- M1: (role, branch) evaluated together --------------------------------------------
create or replace function identity.has_branch_role(p_tenant_id uuid, p_branch_id uuid, p_roles text[])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from identity.memberships m
    join identity.tenants t on t.id = m.tenant_id
    join identity.branches b on b.tenant_id = m.tenant_id and b.id = p_branch_id
    where m.user_id = auth.uid()
      and m.tenant_id = p_tenant_id
      and m.status = 'active' and t.status = 'active'
      and m.role = any (p_roles)
      and (m.branch_id is null or m.branch_id = p_branch_id)   -- tenant_admin is tenant-wide (branch_id null)
      and (identity.active_tenant_claim() is null or m.tenant_id = identity.active_tenant_claim()))
$$;
revoke all on function identity.has_branch_role(uuid, uuid, text[]) from public, anon;
grant execute on function identity.has_branch_role(uuid, uuid, text[]) to authenticated, service_role;

-- Patient READ stays tenant-wide for clinical roles (unchanged). Writes need the role AT the branch.
drop policy if exists patients_insert_registry_writers on patient.patients;
create policy patients_insert_registry_writers on patient.patients for insert to authenticated
  with check (identity.has_branch_role(tenant_id, registered_branch_id, array['tenant_admin','doctor','nurse','receptionist']));
drop policy if exists patients_update_registry_writers on patient.patients;
create policy patients_update_registry_writers on patient.patients for update to authenticated
  using (identity.has_branch_role(tenant_id, registered_branch_id, array['tenant_admin','doctor','nurse','receptionist']))
  with check (identity.has_branch_role(tenant_id, registered_branch_id, array['tenant_admin','doctor','nurse','receptionist']));

-- ---- M1: tenant_admin is tenant-wide ---------------------------------------------------
-- Existing branch-scoped tenant_admin rows, per (tenant, user):
--   A. no tenant-wide row, one branch row      -> branch_id := null (keeps today's effective access:
--                                                 has_tenant_role already ignored branch_id)
--   B. no tenant-wide row, several branch rows -> keep one (active first, oldest, id) as tenant-wide,
--                                                 delete the rest
--   C. tenant-wide tenant_admin row is active  -> delete the redundant branch rows
--   D. anything else where a branch row is active (tenant-wide row has another role or is not
--      active) -> RAISE: ambiguous, needs a human decision.  Every change is RAISE NOTICEd and
--      captured by audit.audit_log (memberships_audit_log trigger).
do $$
declare r record; v_keep uuid; v_tw record;
begin
  for r in select distinct tenant_id, user_id from identity.memberships where role = 'tenant_admin' and branch_id is not null loop
    select * into v_tw from identity.memberships where tenant_id = r.tenant_id and user_id = r.user_id and branch_id is null;
    if v_tw.id is null then
      select id into v_keep from identity.memberships
       where tenant_id = r.tenant_id and user_id = r.user_id and role = 'tenant_admin' and branch_id is not null
       order by (status = 'active') desc, created_at, id limit 1;
      delete from identity.memberships
       where tenant_id = r.tenant_id and user_id = r.user_id and role = 'tenant_admin' and branch_id is not null and id <> v_keep;
      update identity.memberships set branch_id = null where id = v_keep;
      raise notice 'tenant_admin %: membership % made tenant-wide (other branch-scoped admin rows deleted)', r.user_id, v_keep;
    elsif v_tw.role = 'tenant_admin' and v_tw.status = 'active' then
      delete from identity.memberships where tenant_id = r.tenant_id and user_id = r.user_id and role = 'tenant_admin' and branch_id is not null;
      raise notice 'tenant_admin %: redundant branch-scoped admin rows deleted (tenant-wide row % kept)', r.user_id, v_tw.id;
    elsif exists (select 1 from identity.memberships where tenant_id = r.tenant_id and user_id = r.user_id
                    and role = 'tenant_admin' and branch_id is not null and status = 'active') then
      raise exception 'ambiguous branch-scoped tenant_admin for user % in tenant % (tenant-wide row % is %/%); resolve manually',
        r.user_id, r.tenant_id, v_tw.id, v_tw.role, v_tw.status;
    else
      delete from identity.memberships where tenant_id = r.tenant_id and user_id = r.user_id and role = 'tenant_admin' and branch_id is not null;
      raise notice 'tenant_admin %: inactive branch-scoped admin rows deleted', r.user_id;
    end if;
  end loop;
end $$;
alter table identity.memberships
  add constraint memberships_tenant_admin_tenant_wide check (role <> 'tenant_admin' or branch_id is null);

-- ---- M2: actor wins; clients cannot write audit columns ---------------------------------
create or replace function audit.stamp_audit_columns()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.created_by := coalesce(auth.uid(), new.created_by);
    new.updated_at := new.created_at;
    new.updated_by := new.created_by;
  elsif tg_op = 'UPDATE' then
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := coalesce(auth.uid(), new.updated_by);
  end if;
  return new;
end $$;
revoke all on function audit.stamp_audit_columns() from public;
revoke insert (created_at, created_by, updated_at, updated_by, deleted_at) on patient.patients from authenticated;
revoke update (updated_at, updated_by) on patient.patients from authenticated;
-- identity.branches / identity.memberships have TABLE-level insert/update grants (cover audit columns):
revoke insert, update on identity.branches from authenticated;
grant insert (id, tenant_id, code, name, timezone, is_active) on identity.branches to authenticated;
grant update (code, name, timezone, is_active) on identity.branches to authenticated;
revoke insert, update on identity.memberships from authenticated;
grant insert (id, tenant_id, user_id, branch_id, role, status) on identity.memberships to authenticated;
grant update (branch_id, role, status) on identity.memberships to authenticated;

-- ---- Minor 10/11: patient data limits (fail loudly on existing violators; never truncate PHI) ----
do $$
declare v_phone int; v_email int; v_mrn int;
begin
  select count(*) into v_phone from patient.patients where length(phone) > 32;
  select count(*) into v_email from patient.patients where length(email) > 254;
  select count(*) into v_mrn from (select 1 from patient.patients group by tenant_id, upper(mrn) having count(*) > 1) d;
  if v_phone + v_email + v_mrn > 0 then
    raise exception 'patient data violates new limits: % phone > 32, % email > 254, % case-insensitive MRN duplicate groups; fix data first',
      v_phone, v_email, v_mrn;
  end if;
end $$;
alter table patient.patients
  add constraint patients_phone_length check (phone is null or length(phone) <= 32),
  add constraint patients_email_length check (email is null or length(email) <= 254);
create unique index patients_tenant_mrn_upper_key on patient.patients (tenant_id, upper(mrn));

-- ---- Minor 8: FORCE RLS (only where the owner bypasses RLS, else definer helpers would break) ----
do $$
declare r record;
begin
  for r in select c.oid::regclass as t, ro.rolsuper or ro.rolbypassrls as ok
           from pg_class c join pg_roles ro on ro.oid = c.relowner
           where c.relnamespace in ('identity'::regnamespace, 'patient'::regnamespace, 'audit'::regnamespace) and c.relkind = 'r' loop
    if r.ok then execute format('alter table %s force row level security', r.t);
    else raise notice 'FORCE RLS skipped on % (owner lacks BYPASSRLS)', r.t; end if;
  end loop;
end $$;

-- ---- Minor 1: hms_api trust model --------------------------------------------------------
comment on role hms_api is
  'HMS API: no direct privileges; switches to authenticated/anon per transaction so RLS applies. '
  'TRUST MODEL: the DB trusts the sub/tenant_id claims the API sets (same as PostgREST authenticator), '
  'so hms_api_login can act as any user. Treat its password like service_role (secret store, rotation), '
  'restrict network access, and set a CONNECTION LIMIT.';
