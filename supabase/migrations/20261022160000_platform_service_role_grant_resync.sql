-- cross-schema: approved (re-runs the own-schema copy from 20261022140000 for service roles only;
-- reviewed with ADR 0002. Grants nothing cross-schema.)
-- Re-sync hms_svc_* grants and RLS policy roles from `authenticated`, per owned schema.
--
-- 20261022150000 (practitioner_branches, schedule_overrides, tenant_settings) sorts after
-- 20261022140000, so on a fresh chain its tables and policies were created after the one-time
-- copy ran: hms_svc_scheduling got no grants and scheduling writes failed with
-- 42501 permission denied for table practitioner_branches. This block is idempotent.
-- Future migrations that add tables in a service schema must grant the hms_svc_* role directly
-- (or re-run this block).

set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ---------------------------------------------------------------- own-schema grants + policies ----
do $$
declare
  v_schema text;
  v_role text;
  r record;
begin
  for v_schema, v_role in
    select * from (values
      ('identity', 'hms_svc_identity'),
      ('patient', 'hms_svc_patients'),
      ('appointment', 'hms_svc_scheduling')
    ) as t(schema_name, role_name)
  loop
    execute format('grant usage on schema %I to %I', v_schema, v_role);

    -- pg_catalog, not information_schema: the information_schema views hide grants
    -- unless the current role is the grantor, the grantee, or a superuser that
    -- pg_has_role treats as a member. Catalog ACLs are what the migration role sees.
    for r in
      select n.nspname as table_schema, c.relname as table_name, x.privilege_type
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      cross join lateral aclexplode(c.relacl) x
      join pg_roles gr on gr.oid = x.grantee
      where n.nspname = v_schema
        and c.relkind in ('r', 'p', 'v', 'm')
        and gr.rolname = 'authenticated'
        and x.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER')
    loop
      execute format(
        'grant %s on table %I.%I to %I',
        r.privilege_type, r.table_schema, r.table_name, v_role);
    end loop;

    for r in
      select n.nspname as table_schema, c.relname as table_name, x.privilege_type,
             string_agg(quote_ident(att.attname), ', ' order by att.attname) as cols
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute att on att.attrelid = c.oid and att.attnum > 0 and not att.attisdropped
      cross join lateral aclexplode(att.attacl) x
      join pg_roles gr on gr.oid = x.grantee
      where n.nspname = v_schema
        and c.relkind in ('r', 'p', 'v', 'm')
        and gr.rolname = 'authenticated'
        and x.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
      group by n.nspname, c.relname, x.privilege_type
    loop
      execute format(
        'grant %s (%s) on table %I.%I to %I',
        r.privilege_type, r.cols, r.table_schema, r.table_name, v_role);
    end loop;

    for r in
      select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = v_schema
        and has_function_privilege('authenticated', p.oid, 'execute')
    loop
      execute format('grant execute on function %s to %I', r.sig, v_role);
    end loop;

    -- has_sequence_privilege() errors on a non-sequence. Keep it out of the SELECT:
    -- the planner may call a WHERE function before the relkind filter.
    for r in
      select n.nspname, c.relname, c.oid
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = v_schema
        and c.relkind = 'S'
    loop
      if has_sequence_privilege('authenticated', r.oid, 'usage') then
        execute format('grant usage, select on sequence %I.%I to %I', r.nspname, r.relname, v_role);
      end if;
    end loop;

    for r in
      select n.nspname as schema_name, c.relname, pol.polname,
             (
               select string_agg(quote_ident(rr.rolname), ', ' order by rr.rolname)
               from pg_roles rr
               where rr.oid = any (pol.polroles)
             ) as roles
      from pg_policy pol
      join pg_class c on c.oid = pol.polrelid
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = v_schema
        and not (0 = any (pol.polroles))
        and not exists (
          select 1 from pg_roles rr
          where rr.oid = any (pol.polroles) and rr.rolname = v_role)
    loop
      if r.roles is null then
        continue;
      end if;
      execute format(
        'alter policy %I on %I.%I to %s, %I',
        r.polname, r.schema_name, r.relname, r.roles, v_role);
    end loop;
  end loop;
end
$$;

