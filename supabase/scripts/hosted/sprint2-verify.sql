-- READ-ONLY post-apply verification (docs/runbooks/deploy-sprint-2-hosted.md §5). Every *_ok column must be true.
with h as (select array_agg(version order by version) v from supabase_migrations.schema_migrations)
select
  (select v from h) = array['20261006090000','20261006090100','20261006090200','20261006090300','20261006090400',
                            '20261006090500','20261006090600','20261007090000','20261008090000','20261009090000',
                            '20261010090000','20261010090100','20261010090200','20261010090300','20261010090400']::text[]
                                                                                        as history_ok,
  -- N1 (20261009090000)
  (select column_default from information_schema.columns where table_schema='identity' and table_name='memberships'
     and column_name='status') = '''invited''::text'                                    as n1_status_default_ok,
  not has_function_privilege('hms_api', 'identity.accept_membership(uuid)', 'execute')
    and not has_function_privilege('hms_api', 'identity.my_invitations()', 'execute')   as n1_hms_api_revoked_ok,
  -- 20261010090000
  (select count(*) = 2 from information_schema.columns where table_schema='patient' and table_name='patients'
     and column_name in ('deleted_by','deletion_reason'))                               as s2_patient_cols_ok,
  not has_column_privilege('authenticated', 'patient.patients', 'deleted_at', 'UPDATE') as s2_deleted_at_rpc_only_ok,
  (select count(*) = 4 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='patient'
     and p.proname in ('normalize_phone','soft_delete_patient','restore_patient','find_duplicate_patients')) as s2_patient_fns_ok,
  -- 20261010090100 / 090200 / 090300
  (select count(*) = 5 from pg_tables where schemaname='appointment'
     and tablename in ('practitioners','schedules','appointments','queue_counters','queue_entries'))
   and (select count(*) = 1 from pg_tables where schemaname='messaging' and tablename='outbox') as s2_appointment_tables_ok,
  (select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where (n.nspname='appointment' and c.relname in ('practitioners','schedules','appointments','queue_counters','queue_entries'))
       or (n.nspname='messaging' and c.relname='outbox'))                               as s2_rls_enabled_ok,
  (select extversion is not null from pg_extension where extname='btree_gist')          as s2_btree_gist_ok,
  (select count(*) = 2 from pg_constraint where conname in ('schedules_no_overlap','appointments_no_practitioner_overlap')) as s2_exclusion_ok,
  has_function_privilege('authenticated', 'appointment.check_in(uuid,uuid,uuid,uuid,uuid)', 'execute')
    and has_function_privilege('authenticated', 'appointment.check_in_walk_in(uuid,uuid,uuid)', 'execute')
    and has_function_privilege('authenticated', 'appointment.set_queue_status(uuid,text)', 'execute')
    and has_function_privilege('authenticated', 'appointment.available_slots(uuid,uuid,date,date,uuid)', 'execute') as s2_rpc_grants_ok,
  not has_function_privilege('authenticated', 'appointment.issue_queue_token(uuid,uuid,uuid,uuid,uuid)', 'execute')
    and not has_function_privilege('anon', 'appointment.check_in(uuid,uuid,uuid,uuid,uuid)', 'execute')
    and not has_function_privilege('authenticated', 'messaging.claim_outbox(text,integer,interval)', 'execute') as s2_no_client_internal_exec_ok,
  not has_table_privilege('authenticated', 'appointment.queue_entries', 'INSERT')
    and not has_table_privilege('authenticated', 'messaging.outbox', 'SELECT')          as s2_no_client_dml_ok,
  -- outbox dispatcher role chain: hms_api_login -> hms_api -> hms_dispatcher (SET option)
  exists (select 1 from pg_auth_members am join pg_roles r on r.oid=am.roleid join pg_roles m on m.oid=am.member
          where r.rolname='hms_dispatcher' and m.rolname='hms_api' and am.set_option)   as s2_dispatcher_grant_ok,
  (select not rolcanlogin and not rolinherit from pg_roles where rolname='hms_dispatcher') as s2_dispatcher_nologin_ok,
  has_function_privilege('hms_dispatcher', 'messaging.claim_outbox(text,integer,interval)', 'execute') as s2_dispatcher_exec_ok,
  pg_has_role('hms_api_login', 'hms_dispatcher', 'SET') and pg_has_role('hms_api_login', 'authenticated', 'SET')
    and not pg_has_role('hms_api_login', 'hms_dispatcher', 'USAGE')                    as s2_api_login_can_set_role_ok,
  -- 20261010090400
  exists (select 1 from pg_trigger where tgname='appointments_cancel_queue_entry' and not tgisinternal) as s2_maj1_trigger_ok,
  (select qual like '%can_access_branch%' from pg_policies where schemaname='patient'
     and tablename='patients' and policyname='patients_update_registry_writers')       as s2_min3_policy_ok,
  -- data untouched by the DDL
  (select count(*) from patient.patients)                                               as patients_now,
  (select count(*) from identity.memberships)                                           as memberships_now;
