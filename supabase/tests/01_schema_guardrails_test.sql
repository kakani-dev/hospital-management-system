-- Structural guardrails: every tenant-owned table has a NOT NULL tenant_id, RLS is on,
-- anon has no table privileges, helper functions are hardened.
begin;

select tests.ok(
  not exists (
    select 1
    from information_schema.tables t
    where t.table_schema in ('identity', 'patient', 'audit')
      and t.table_type = 'BASE TABLE'
      and t.table_name not in ('tenants', 'user_profiles') -- tenant root + global profile (documented exceptions)
      and not exists (
        select 1 from information_schema.columns c
        where c.table_schema = t.table_schema and c.table_name = t.table_name
          and c.column_name = 'tenant_id' and c.is_nullable = 'NO')
  ),
  'every tenant-owned table has a NOT NULL tenant_id column');

select tests.ok(
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('identity', 'patient', 'audit') and c.relkind = 'r' and not c.relrowsecurity
  ),
  'RLS is enabled on every table in identity, patient, audit');

select tests.ok(
  not exists (
    select 1 from information_schema.role_table_grants
    where grantee in ('anon', 'PUBLIC') and table_schema in ('identity', 'patient', 'audit')
  ),
  'anon/PUBLIC have no table privileges in HMS schemas');

select tests.ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('identity', 'audit') and p.prosecdef
      and not coalesce(p.proconfig @> array['search_path=""'], false)
  ),
  'every SECURITY DEFINER function pins an empty search_path');

select tests.ok(
  not has_function_privilege('anon', 'identity.current_tenant_ids()', 'execute'),
  'anon cannot execute identity.current_tenant_ids()');

select tests.ok(
  (select count(*) from pg_constraint where conname in (
    'branches_tenant_code_key', 'patients_tenant_mrn_key', 'memberships_branch_same_tenant', 'patients_branch_same_tenant')) = 4,
  'tenant-scoped unique and composite FK constraints exist');

select tests.ok(
  not has_function_privilege('anon', 'audit.log_row_change()', 'execute')
  and not has_function_privilege('authenticated', 'audit.log_row_change()', 'execute'),
  'clients cannot call the SECURITY DEFINER audit trigger function directly');

select tests.ok(
  exists (
    select 1 from pg_index i
    where i.indrelid = 'identity.memberships'::regclass
      and (i.indkey::int2[])[0:1] = (select array_agg(attnum order by attnum)::int2[] from pg_attribute
                                      where attrelid = 'identity.memberships'::regclass and attname in ('tenant_id', 'branch_id'))
  ),
  'composite FK memberships(tenant_id, branch_id) has a covering index');

rollback;
