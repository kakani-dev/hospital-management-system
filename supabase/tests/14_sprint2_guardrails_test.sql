-- Sprint 2 schema guardrails for the new schemas (appointment, messaging) and the new patient RPCs.
begin;

select tests.ok(
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('appointment', 'messaging') and c.relkind in ('r', 'p') and not c.relrowsecurity),
  'RLS is enabled on every table in appointment and messaging');
select tests.ok(
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('appointment', 'messaging') and c.relkind in ('r', 'p')
      and not exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'tenant_id' and a.attnotnull)),
  'every new table has tenant_id NOT NULL');
select tests.ok(
  not exists (
    select 1 from information_schema.role_table_grants
    where table_schema in ('appointment', 'messaging') and grantee in ('anon', 'PUBLIC')),
  'anon / PUBLIC hold no table privileges in appointment or messaging');
select tests.ok(
  not exists (
    select 1 from pg_namespace n
    where n.nspname in ('appointment', 'messaging')
      and (has_schema_privilege('anon', n.oid, 'USAGE') or has_schema_privilege('public', n.oid, 'USAGE'))),
  'anon / PUBLIC have no USAGE on appointment or messaging');
select tests.ok(
  not has_schema_privilege('authenticated', 'messaging', 'USAGE'),
  'authenticated has no USAGE on messaging');
select tests.ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('patient', 'appointment', 'messaging') and p.prosecdef
      and not coalesce(p.proconfig @> array['search_path=""'], false)),
  'every SECURITY DEFINER function in patient / appointment / messaging pins search_path=''''');
select tests.ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('patient', 'appointment', 'messaging') and p.prosecdef
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('public', p.oid, 'execute'))),
  'anon / PUBLIC cannot execute any SECURITY DEFINER function in the new schemas');
select tests.ok(
  not exists (
    select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'appointment' and c.relkind = 'r' and c.relname <> 'queue_counters'
    group by c.oid
    having count(*) filter (where t.tgfoid = 'audit.log_row_change'::regproc) = 0
        or count(*) filter (where t.tgfoid = 'audit.prevent_tenant_change'::regproc) = 0
        or count(*) filter (where t.tgfoid = 'audit.stamp_audit_columns'::regproc) = 0),
  'appointment tables carry the audit, tenant-immutable and audit-stamp triggers');
select tests.ok(
  not exists (
    select 1 from pg_constraint fk join pg_class c on c.oid = fk.conrelid join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'appointment' and fk.contype = 'f'
      and fk.confrelid <> 'identity.tenants'::regclass and fk.confrelid <> 'auth.users'::regclass
      and (select a.attname from pg_attribute a where a.attrelid = fk.conrelid and a.attnum = fk.conkey[1]) <> 'tenant_id'),
  'every appointment-schema FK to a tenant-owned parent is composite and leads with tenant_id');

rollback;
