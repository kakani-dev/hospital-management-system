-- READ-ONLY pre-check for the Sprint 2 hosted apply (docs/runbooks/deploy-sprint-2-hosted.md §2).
-- Safe to run any number of times (Supabase MCP execute_sql or psql). Changes nothing.
select
  current_setting('server_version')                                                     as pg_version,      -- expect 17.x
  (select array_agg(version order by version) from supabase_migrations.schema_migrations) as history,       -- expect the 9 versions 20261006090000..20261008090000
  (select count(*) from supabase_migrations.schema_migrations where version >= '20261009090000') as pending_rows_present, -- expect 0
  (select column_default from information_schema.columns
    where table_schema = 'identity' and table_name = 'memberships' and column_name = 'status') as membership_status_default, -- 'active' before N1, 'invited' after
  has_function_privilege('hms_api', 'identity.accept_membership(uuid)', 'execute')    as hms_api_exec_accept,          -- true before N1, false after
  (select count(*) from pg_namespace where nspname in ('appointment', 'messaging'))    as sprint2_schemas_present,      -- expect 0
  (select count(*) from pg_roles where rolname = 'hms_dispatcher')                      as hms_dispatcher_present,       -- expect 0
  (select extversion from pg_extension where extname = 'btree_gist')                    as btree_gist_installed,         -- expect null (installed by 20261010090100)
  (select default_version from pg_available_extensions where name = 'btree_gist')       as btree_gist_available,         -- expect non-null
  (select count(*) from information_schema.columns
    where table_schema = 'patient' and table_name = 'patients' and column_name in ('deleted_by', 'deletion_reason')) as patient_new_cols, -- expect 0
  (select count(*) from patient.patients where deleted_at is not null)                  as patients_soft_deleted,        -- informational
  (select count(*) from pg_roles where rolname in ('hms_api', 'hms_api_login'))         as api_roles,                    -- expect 2
  (select rolconnlimit from pg_roles where rolname = 'hms_api_login')                   as api_login_connlimit,          -- expect 20
  (select count(*) from pg_stat_activity where usename = 'hms_api_login')              as api_login_sessions,           -- informational
  (select json_object_agg(t, n) from (
     select 'tenants' t, count(*) n from identity.tenants union all
     select 'branches', count(*) from identity.branches union all
     select 'memberships', count(*) from identity.memberships union all
     select 'user_profiles', count(*) from identity.user_profiles union all
     select 'patients', count(*) from patient.patients union all
     select 'audit_log', count(*) from audit.audit_log) c)                               as row_counts;
