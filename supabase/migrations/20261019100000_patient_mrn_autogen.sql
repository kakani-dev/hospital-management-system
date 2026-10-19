-- =============================================================================
-- Level 1: server-generated MRNs. Users never type or edit an MRN.
--
--   patient.mrn_counters   one row per tenant (NOT one global sequence). The next number is taken
--                          with an atomic INSERT ... ON CONFLICT DO UPDATE ... RETURNING, which
--                          row-locks the tenant's counter until the inserting transaction ends, so
--                          concurrent registrations in one tenant serialise on that row and never
--                          get the same number; tenants never contend with each other.
--   patient.assign_mrn()   BEFORE INSERT trigger on patient.patients:
--                          mrn = upper(<tenant code>) || '-' || <number zero-padded to 6 digits>
--                          e.g. ALPHA-000123 (numbers above 999999 simply grow: ALPHA-1000000).
--                          Any MRN a client role supplies is IGNORED and replaced. Only a direct
--                          owner/superuser session (seed data, legacy imports run by an operator)
--                          may keep an explicit MRN; the counter is then bumped past its numeric
--                          suffix so a generated MRN can never collide with it.
--   patient.guard_mrn()    BEFORE UPDATE trigger: the MRN is immutable for everyone (like tenant_id).
--
-- Clients additionally lose the INSERT (mrn) / UPDATE (mrn) column privileges, so a client
-- statement that names mrn is refused outright (42501), exactly like the audit columns.
-- Existing patients keep their MRNs; each tenant's counter is seeded with the largest trailing
-- numeric suffix among its existing MRNs (deleted rows included: an MRN is never reused), so the
-- first generated number is above every existing one.
-- =============================================================================
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ------------------------------------------------------------------ table ----
create table patient.mrn_counters (
  tenant_id   uuid primary key references identity.tenants (id) on delete cascade,
  last_value  bigint not null default 0,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  constraint mrn_counters_non_negative check (last_value >= 0),
  constraint mrn_counters_never_deleted check (not is_deleted)
);
comment on table patient.mrn_counters is
  'Per-tenant MRN counter. Written only by the patient.assign_mrn() trigger (upsert = row lock); no client grants.';

alter table patient.mrn_counters enable row level security;  -- no policies: trigger-only
revoke all on patient.mrn_counters from public, anon, authenticated;
grant all on patient.mrn_counters to service_role;

create trigger mrn_counters_audit_columns before insert or update on patient.mrn_counters
  for each row execute function audit.stamp_audit_columns();
create trigger mrn_counters_audit_log after insert or update or delete on patient.mrn_counters
  for each row execute function audit.log_row_change();

-- ---------------------------------------------------- MRN shape (wider) ----
-- tenant codes are up to 40 characters, plus '-' and at least 6 digits
alter table patient.patients drop constraint patients_mrn_format;
alter table patient.patients add constraint patients_mrn_format check (mrn ~ '^[A-Za-z0-9-]{1,64}$');

-- ----------------------------------------------------------- functions ----
-- identity publishes the MRN prefix (R3: patient functions never read identity tables directly).
-- Owner-only: called by the SECURITY DEFINER trigger below, not by clients.
-- cross-schema: approved (Level 1 MRN / phone normalization; consumers: patient)
create or replace function identity.tenant_mrn_prefix_v1(p_tenant_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.upper(t.code) from identity.tenants t where t.id = p_tenant_id;
$$;
revoke all on function identity.tenant_mrn_prefix_v1(uuid) from public, anon, authenticated;
grant execute on function identity.tenant_mrn_prefix_v1(uuid) to service_role;

create or replace function patient.mrn_numeric_suffix(p_mrn text)
returns bigint
language sql
immutable
set search_path = ''
as $$
  -- trailing digits (at most 18, so the value always fits a bigint); NULL when there are none
  select nullif(pg_catalog.substring(p_mrn, '([0-9]{1,18})$'), '')::bigint;
$$;
revoke all on function patient.mrn_numeric_suffix(text) from public;

create or replace function patient.assign_mrn()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_n bigint;
  -- current_setting('role') is the SET ROLE of the calling session (it is NOT changed by SECURITY
  -- DEFINER). API services and PostgREST always SET ROLE authenticated/service_role, so only a raw
  -- owner/superuser session (seed, operator import) is privileged.
  v_privileged boolean := pg_catalog.current_setting('role') = 'none'
    and exists (select 1 from pg_catalog.pg_roles r
                where r.rolname = session_user and (r.rolsuper or r.rolname in ('postgres', 'supabase_admin')));
begin
  v_code := identity.tenant_mrn_prefix_v1(new.tenant_id);
  if v_code is null then
    return new;  -- the tenant FK rejects the row
  end if;

  if v_privileged and new.mrn is not null then
    -- explicit MRN (seed / legacy import): keep it, move the counter past its number
    insert into patient.mrn_counters as c (tenant_id, last_value)
    values (new.tenant_id, coalesce(patient.mrn_numeric_suffix(new.mrn), 0))
    on conflict (tenant_id) do update
      set last_value = greatest(c.last_value, excluded.last_value)
      where excluded.last_value > c.last_value;
    return new;
  end if;

  insert into patient.mrn_counters as c (tenant_id, last_value)
  values (new.tenant_id, 1)
  on conflict (tenant_id) do update set last_value = c.last_value + 1
  returning c.last_value into v_n;

  new.mrn := v_code || '-' || case when v_n < 1000000 then pg_catalog.lpad(v_n::text, 6, '0') else v_n::text end;
  return new;
end;
$$;
revoke all on function patient.assign_mrn() from public, anon, authenticated;

create or replace function patient.guard_mrn()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.mrn is distinct from old.mrn then
    raise exception 'mrn is immutable' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function patient.guard_mrn() from public, anon, authenticated;

-- "a_" sorts first: the MRN exists before the audit-column / tenant guards see the row
create trigger a_patients_assign_mrn before insert on patient.patients
  for each row execute function patient.assign_mrn();
create trigger patients_mrn_immutable before update of mrn on patient.patients
  for each row execute function patient.guard_mrn();

-- ------------------------------------------------------ client privileges ----
revoke insert (mrn) on patient.patients from authenticated;
revoke update (mrn) on patient.patients from authenticated;

-- ------------------------------------------------------------ seed counters ----
insert into patient.mrn_counters (tenant_id, last_value)
select t.id, coalesce(max(patient.mrn_numeric_suffix(p.mrn)), 0)
from identity.tenants t
left join patient.patients p on p.tenant_id = t.id
group by t.id
on conflict (tenant_id) do nothing;
