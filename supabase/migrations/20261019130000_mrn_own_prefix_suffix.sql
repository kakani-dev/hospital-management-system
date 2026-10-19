-- =============================================================================
-- Fix (Level 1 polish): MRN counters must only count the tenant's OWN MRN format.
--
-- 20261019100000 bumped / seeded patient.mrn_counters with patient.mrn_numeric_suffix(mrn): the
-- trailing digits of ANY MRN. A legacy or foreign-prefixed MRN such as SMOKE-20261009114530 (or
-- MRN-1001 / ALP-0003 in the demo seed) therefore inflated the counter (to 20261009114530), and
-- every MRN generated afterwards jumped to that number.
--
-- Now only MRNs of the exact shape '<UPPER(tenant code)>-<1..18 digits>' (compared
-- case-insensitively) count, both for privileged explicit inserts (seed / operator imports) and for
-- seeding. Any other MRN is kept as-is but never moves the counter: it can never collide with a
-- generated MRN, because generated MRNs always have the tenant's own prefix.
--
-- Data: none. Counters are NEVER changed here: lowering could re-issue a number, and raising to the
-- largest own-format MRN is wrong too, because the bug itself issued own-format MRNs with huge numbers
-- (hosted Alpha has DEMO-ALPHA-20261009114531 while its counter was reset by hand to 1001). Such an
-- MRN cannot collide with generated ones for trillions of registrations, and the unique
-- (tenant_id, mrn) index would refuse a collision rather than duplicate it.
-- =============================================================================
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- Numeric part of an MRN when it is '<prefix>-<digits>' for exactly this prefix; NULL otherwise.
-- Pure string comparison (no regex built from the prefix, so codes with regex metacharacters are safe).
create or replace function patient.mrn_own_suffix(p_mrn text, p_prefix text)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select case
    when p_mrn is null or p_prefix is null or p_prefix = '' then null
    when pg_catalog.upper(pg_catalog.left(p_mrn, pg_catalog.length(p_prefix) + 1)) <> pg_catalog.upper(p_prefix) || '-' then null
    when pg_catalog.substr(p_mrn, pg_catalog.length(p_prefix) + 2) ~ '^[0-9]{1,18}$'
      then pg_catalog.substr(p_mrn, pg_catalog.length(p_prefix) + 2)::bigint
    else null
  end;
$$;
revoke all on function patient.mrn_own_suffix(text, text) from public, anon, authenticated;
comment on function patient.mrn_own_suffix(text, text) is
  'Numeric suffix of an MRN in the tenant''s own <PREFIX>-<digits> format (case-insensitive), else NULL.';

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
    -- explicit MRN (seed / legacy import): keep it; only an own-format MRN moves the counter past
    -- its number (a foreign/legacy prefix can never collide with a generated MRN)
    insert into patient.mrn_counters as c (tenant_id, last_value)
    values (new.tenant_id, coalesce(patient.mrn_own_suffix(new.mrn, v_code), 0))
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

-- The any-trailing-digits helper caused the bug; nothing else uses it.
drop function patient.mrn_numeric_suffix(text);
