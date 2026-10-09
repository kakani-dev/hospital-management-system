-- READ-ONLY catalog fingerprint of the app schemas (functions, policies, grants, columns, constraints,
-- triggers, roles). Run before AND after the apply; save both; diff them (runbook §1, §5).
with s(n) as (values ('identity'), ('patient'), ('audit'), ('appointment'), ('messaging'))
select jsonb_build_object(
  'functions', (select jsonb_object_agg(p.oid::regprocedure::text, md5(pg_get_functiondef(p.oid)))
                from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in (select n from s) and p.prokind = 'f'),
  'function_acl', (select jsonb_object_agg(p.oid::regprocedure::text, coalesce(p.proacl::text, 'default'))
                from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in (select n from s) and p.prokind = 'f'),
  'policies', (select jsonb_object_agg(schemaname || '.' || tablename || '.' || policyname,
                 md5(coalesce(cmd, '') || coalesce(roles::text, '') || coalesce(qual, '') || coalesce(with_check, '')))
               from pg_policies where schemaname in (select n from s)),
  'table_acl', (select jsonb_object_agg(n.nspname || '.' || c.relname, coalesce(c.relacl::text, 'default') || ' rls=' || c.relrowsecurity)
               from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname in (select n from s) and c.relkind in ('r', 'p', 'v')),
  'columns', (select jsonb_object_agg(table_schema || '.' || table_name || '.' || column_name,
                data_type || coalesce(' default ' || column_default, '') || ' null=' || is_nullable)
              from information_schema.columns where table_schema in (select n from s)),
  'constraints', (select jsonb_object_agg(n.nspname || '.' || co.conname, md5(pg_get_constraintdef(co.oid)))
                  from pg_constraint co join pg_namespace n on n.oid = co.connamespace where n.nspname in (select n from s)),
  'triggers', (select jsonb_object_agg(n.nspname || '.' || c.relname || '.' || t.tgname, md5(pg_get_triggerdef(t.oid)))
               from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
               where not t.tgisinternal and n.nspname in (select n from s)),
  'roles', (select jsonb_object_agg(rolname, jsonb_build_object('login', rolcanlogin, 'inherit', rolinherit, 'connlimit', rolconnlimit))
            from pg_roles where rolname in ('hms_api', 'hms_api_login', 'hms_dispatcher')),
  'extensions', (select jsonb_object_agg(extname, extversion) from pg_extension)
) as fingerprint;
