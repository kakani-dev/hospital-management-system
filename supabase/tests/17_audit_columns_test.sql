-- Audit-column convention v2 (migration 20261012090000): the CI GUARD for the five mandatory
-- columns, client-forgery attempts, actor fallback, immutability and the user_profiles audit log.
begin;

-- =====================================================================  CI GUARD ==
-- Every base table in identity / patient / appointment must have the five columns, NOT NULL,
-- with the right types and defaults, the shared stamping trigger, and no client write privilege
-- on them. audit.audit_log and messaging.outbox are exempt (decision E2: other schemas).
create temporary table t_guard_tables on commit drop as
  select t.table_schema, t.table_name
  from information_schema.tables t
  where t.table_schema in ('identity', 'patient', 'appointment') and t.table_type = 'BASE TABLE';

select tests.ok((select count(*) from t_guard_tables) >= 11, 'guard covers every business table (>= 11 found)');

select tests.ok(
  not exists (
    select 1 from t_guard_tables t
    cross join (values ('created_on', 'timestamp with time zone'), ('created_by', 'uuid'),
                       ('updated_on', 'timestamp with time zone'), ('updated_by', 'uuid'),
                       ('is_deleted', 'boolean')) req(col, typ)
    where not exists (
      select 1 from information_schema.columns c
      where c.table_schema = t.table_schema and c.table_name = t.table_name
        and c.column_name = req.col and c.data_type = req.typ and c.is_nullable = 'NO')),
  'GUARD: every table has created_on/created_by/updated_on/updated_by/is_deleted, typed and NOT NULL');

select tests.ok(
  not exists (
    select 1 from t_guard_tables t
    join information_schema.columns c on c.table_schema = t.table_schema and c.table_name = t.table_name
    where (c.column_name in ('created_on', 'updated_on') and coalesce(c.column_default, '') <> 'now()')
       or (c.column_name = 'is_deleted' and c.is_generated = 'NEVER' and coalesce(c.column_default, '') <> 'false')
       or (c.column_name = 'is_deleted' and c.is_generated <> 'NEVER'
           and (c.table_schema, c.table_name) <> ('patient', 'patients'))),
  'GUARD: created_on/updated_on default now(); is_deleted default false (generated only on patients)');

select tests.ok(
  not exists (
    select 1 from t_guard_tables t
    where not exists (
      select 1 from pg_trigger tg
      where tg.tgrelid = format('%I.%I', t.table_schema, t.table_name)::regclass
        and tg.tgfoid = 'audit.stamp_audit_columns()'::regprocedure
        and not tg.tgisinternal and tg.tgenabled <> 'D'
        and (tg.tgtype & 2) = 2      -- BEFORE
        and (tg.tgtype & 4) = 4      -- INSERT
        and (tg.tgtype & 16) = 16)), -- UPDATE
  'GUARD: every table has an enabled BEFORE INSERT OR UPDATE audit.stamp_audit_columns() trigger');

select tests.ok(
  not exists (
    select 1 from information_schema.column_privileges cp
    join t_guard_tables t on t.table_schema = cp.table_schema and t.table_name = cp.table_name
    where cp.grantee in ('authenticated', 'anon', 'PUBLIC', 'hms_api', 'hms_dispatcher')
      and cp.privilege_type in ('INSERT', 'UPDATE')
      and cp.column_name in ('created_on', 'created_by', 'updated_on', 'updated_by', 'is_deleted', 'created_at', 'updated_at')),
  'GUARD: no client role can INSERT/UPDATE any of the five audit columns (nor the legacy created_at/updated_at)');

-- Expand/contract (review B3): a table that still has created_at/updated_at must mirror them via
-- the 'legacy_at' trigger argument until the contract migration drops them.
select tests.ok(
  not exists (
    select 1 from t_guard_tables t
    where exists (select 1 from information_schema.columns c
                  where c.table_schema = t.table_schema and c.table_name = t.table_name and c.column_name = 'created_at')
      and not exists (
        select 1 from pg_trigger tg
        where tg.tgrelid = format('%I.%I', t.table_schema, t.table_name)::regclass
          and tg.tgfoid = 'audit.stamp_audit_columns()'::regprocedure
          and encode(tg.tgargs, 'escape') like '%legacy_at%')),
  'GUARD: every table that still has created_at/updated_at keeps them mirrored (legacy_at)');
select tests.ok(
  (select count(*) from information_schema.columns c join t_guard_tables t using (table_schema, table_name)
   where c.column_name = 'created_at') = 9,
  'expand phase: the 9 pre-existing tables keep created_at/updated_at (dropped by a later contract migration)');

select tests.ok(
  not exists (
    select 1 from information_schema.role_table_grants g
    join t_guard_tables t on t.table_schema = g.table_schema and t.table_name = g.table_name
    where g.grantee in ('authenticated', 'anon') and g.privilege_type = 'DELETE'),
  'GUARD: no client DELETE privilege on business tables (soft delete only)');

select tests.ok(
  not exists (select 1 from information_schema.columns
              where table_schema = 'audit' and table_name = 'audit_log' and column_name = 'is_deleted')
  and not exists (select 1 from information_schema.columns
                  where table_schema = 'messaging' and table_name = 'outbox' and column_name = 'is_deleted'),
  'exempt tables audit.audit_log and messaging.outbox stay as they are');

-- ================================================================ back-fill / seed ==
select tests.ok(
  (select bool_and(created_by = audit.system_actor() and updated_by = audit.system_actor()) from identity.tenants),
  'rows written without a signed-in user carry the MediCore System actor');
select tests.ok(audit.system_actor() = '00000000-0000-4000-8000-00000000005e', 'system actor id is fixed');

-- ======================================================================= forgery ==
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, mrn, first_name, last_name, created_by)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'FRG-1', 'Forged', 'Synthetic',
            '0b000000-0000-4000-8000-000000000001')$$,
  '42501', 'client INSERT naming created_by is refused (no column privilege)');
select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, mrn, first_name, last_name, created_on)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'FRG-2', 'Forged', 'Synthetic', '2000-01-01')$$,
  '42501', 'client INSERT naming created_on is refused');
select tests.throws_ok(
  $$update patient.patients set updated_by = '0b000000-0000-4000-8000-000000000001' where id = 'aa000000-0000-4000-8000-000000000001'$$,
  '42501', 'client UPDATE of updated_by is refused');
select tests.throws_ok(
  $$update appointment.practitioners set is_deleted = true where id = 'c1111111-0000-4000-8000-000000000001'$$,
  '42501', 'client UPDATE of is_deleted is refused');
select tests.throws_ok(
  $$update patient.patients set created_at = '2000-01-01' where id = 'aa000000-0000-4000-8000-000000000001'$$,
  '42501', 'client UPDATE of the legacy created_at is refused');

insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000f1', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
        'Stamped', 'Synthetic');
select tests.ok(
  (select created_by = '0a000000-0000-4000-8000-000000000002' and updated_by = created_by
          and created_on = updated_on and not is_deleted
   from patient.patients where id = 'aa000000-0000-4000-8000-0000000000f1'),
  'a client insert is stamped with auth.uid() for created_by/updated_by');

-- The trigger overwrites forged values even for a role WITH column privileges (owner / service_role).
select tests.as_superuser();
select set_config('request.jwt.claims', '{"sub":"0a000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
insert into appointment.practitioners (id, tenant_id, display_name, created_on, created_by, updated_on, updated_by, is_deleted)
values ('c1111111-0000-4000-8000-0000000000f1', '11111111-1111-4111-8111-111111111111', 'Dr. Forged (synthetic)',
        '2000-01-01', '0b000000-0000-4000-8000-000000000001', '2000-01-01', '0b000000-0000-4000-8000-000000000001', true);
select tests.ok(
  (select created_by = '0a000000-0000-4000-8000-000000000001' and updated_by = created_by
          and created_on > '2026-01-01' and not is_deleted
   from appointment.practitioners where id = 'c1111111-0000-4000-8000-0000000000f1'),
  'forged created_on/created_by/updated_*/is_deleted on INSERT are overwritten by the trigger');

update appointment.practitioners
   set created_by = '0b000000-0000-4000-8000-000000000001', created_on = '2000-01-01', specialty = 'Cardiology'
 where id = 'c1111111-0000-4000-8000-0000000000f1';
select tests.ok(
  (select created_by = '0a000000-0000-4000-8000-000000000001' and created_on > '2026-01-01'
   from appointment.practitioners where id = 'c1111111-0000-4000-8000-0000000000f1'),
  'created_on/created_by are immutable on UPDATE');

-- API/system-job context: no JWT, hms.actor_id set for the transaction
select set_config('request.jwt.claims', '', true);
select set_config('hms.actor_id', '0d000000-0000-4000-8000-000000000001', true);
update appointment.practitioners set specialty = 'Neurology' where id = 'c1111111-0000-4000-8000-0000000000f1';
select tests.ok(
  (select updated_by = '0d000000-0000-4000-8000-000000000001' from appointment.practitioners
   where id = 'c1111111-0000-4000-8000-0000000000f1'),
  'without a JWT the actor falls back to hms.actor_id (system jobs)');
select set_config('hms.actor_id', '', true);
update appointment.practitioners set specialty = 'Oncology' where id = 'c1111111-0000-4000-8000-0000000000f1';
select tests.ok(
  (select updated_by = audit.system_actor() from appointment.practitioners where id = 'c1111111-0000-4000-8000-0000000000f1'),
  'with neither a JWT nor hms.actor_id the actor is the system actor (never NULL)');

-- Defense in depth: even WITH a column grant, a client role cannot flip is_deleted (trigger guard).
grant update (is_deleted) on appointment.practitioners to authenticated;
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$update appointment.practitioners set is_deleted = true where id = 'c1111111-0000-4000-8000-0000000000f1'$$,
  '42501', 'trigger guard: a client role cannot change is_deleted outside the soft-delete functions');
select tests.as_superuser();
revoke update (is_deleted) on appointment.practitioners from authenticated;

-- ================================================== expand/contract mirror (B3) ==
select tests.ok(
  (select created_at = created_on and updated_at = updated_on from appointment.practitioners
   where id = 'c1111111-0000-4000-8000-0000000000f1'),
  'legacy created_at/updated_at mirror created_on/updated_on after insert + updates');
update appointment.practitioners set created_at = '2000-01-01', updated_at = '2000-01-01', specialty = 'ENT'
 where id = 'c1111111-0000-4000-8000-0000000000f1';
select tests.ok(
  (select created_at = created_on and updated_at = updated_on and created_on > '2026-01-01' from appointment.practitioners
   where id = 'c1111111-0000-4000-8000-0000000000f1'),
  'a write to the legacy columns cannot make them drift');
select tests.ok(
  (select bool_and(created_at = created_on and updated_at = updated_on) from patient.patients)
  and (select bool_and(created_at = created_on and updated_at = updated_on) from identity.memberships),
  'back-filled rows: created_on/updated_on equal the legacy values');

-- ======================================================= is_deleted fails closed (S3, R1) ==
select tests.as_superuser();
set local role service_role;
select tests.throws_ok(
  $$update appointment.practitioners set is_deleted = true where id = 'c1111111-0000-4000-8000-0000000000f1'$$,
  '42501', 'a non-owner, non-client role (service_role) cannot flip is_deleted directly');
-- re-review R1: a session setting is not a capability (set_config is callable by every role)
select set_config('hms.soft_delete', 'c1111111-0000-4000-8000-0000000000f1', true);
select tests.throws_ok(
  $$update appointment.practitioners set is_deleted = true where id = 'c1111111-0000-4000-8000-0000000000f1'$$,
  '42501', 'R1: setting hms.soft_delete to the row id does NOT unlock is_deleted for a non-owner');
select set_config('hms.soft_delete', 'a1111111-0000-4000-8000-000000000002', true);
select tests.throws_ok(
  $$update identity.branches set is_deleted = true where id = 'a1111111-0000-4000-8000-000000000002'$$,
  '42501', 'R1: service_role cannot skip soft_delete_branch''s open-activity / last-branch checks via the flag');
select set_config('hms.soft_delete', '', true);
select tests.ok(
  (select prosrc not like '%hms.soft_delete%' from pg_proc where oid = 'audit.stamp_audit_columns()'::regprocedure)
  and not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname in ('identity', 'patient', 'appointment', 'audit') and p.prosrc like '%hms.soft_delete%'),
  'R1: no function reads or sets the hms.soft_delete flag any more');
-- Become the actual table owner: on the Supabase stack the tests run as supabase_admin
-- (a superuser that does NOT own the tables), and superuser alone must not bypass the guard.
select tests.as_owner('appointment.practitioners');
select tests.ok(
  tests.affected_rows($$update appointment.practitioners set is_deleted = true where id = 'c1111111-0000-4000-8000-0000000000f1'$$) = 1,
  'the table owner (what SECURITY DEFINER functions run as) may change is_deleted');
select tests.ok((select is_deleted from appointment.practitioners where id = 'c1111111-0000-4000-8000-0000000000f1'),
  'the owner''s change took effect');
update appointment.practitioners set is_deleted = false where id = 'c1111111-0000-4000-8000-0000000000f1';

-- ======================================== status-lifecycle tables never deleted (S4) ==
select tests.throws_ok($$update appointment.appointments set is_deleted = true where id = 'e1111111-0000-4000-8000-000000000001'$$,
  '23514', 'appointments: CHECK (not is_deleted), cancel is the lifecycle');
select tests.throws_ok($$update identity.tenants set is_deleted = true where id = '11111111-1111-4111-8111-111111111111'$$,
  '23514', 'tenants: CHECK (not is_deleted), status is the lifecycle');
select tests.ok(
  (select count(*) from pg_constraint where conname in
     ('appointments_never_deleted', 'queue_entries_never_deleted', 'queue_counters_never_deleted', 'tenants_never_deleted')
     and contype = 'c' and pg_get_constraintdef(oid) ilike '%NOT is_deleted%') = 4,
  'appointments / queue_entries / queue_counters / tenants all carry CHECK (not is_deleted)');
reset role;

-- ======================================================== patients: one predicate (S5) ==
select tests.ok(
  (select attgenerated = 's' from pg_attribute where attrelid = 'patient.patients'::regclass and attname = 'is_deleted')
  and pg_get_expr((select adbin from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
                    where d.adrelid = 'patient.patients'::regclass and a.attname = 'is_deleted'), 'patient.patients'::regclass)
      ilike '%deleted_at IS NOT NULL%',
  'patients.is_deleted is GENERATED ALWAYS AS (deleted_at IS NOT NULL) STORED');
select tests.throws_ok($$update patient.patients set is_deleted = true where id = 'aa000000-0000-4000-8000-000000000001'$$,
  '428C9', 'patients.is_deleted cannot be written, not even by the owner');
select tests.ok(
  (select pg_get_indexdef('patient.patients_tenant_mrn_key'::regclass) not ilike '%where%'),
  'patients_tenant_mrn_key stays a FULL unique key (an MRN is never reused)');
select tests.ok(
  not exists (select 1 from pg_index i where i.indrelid = 'patient.patients'::regclass
              and pg_get_indexdef(i.indexrelid) ilike '%deleted_at%')
  and (select count(*) from pg_index i where i.indrelid = 'patient.patients'::regclass
       and pg_get_indexdef(i.indexrelid) ilike '%WHERE (NOT is_deleted)%') = 5,
  'the 5 partial patient indexes (incl. patients_tenant_created_idx, 20261020130000) use NOT is_deleted (no deleted_at predicate left)');
select tests.ok(
  not exists (select 1 from pg_policy where polrelid = 'patient.patients'::regclass
              and (coalesce(pg_get_expr(polqual, polrelid), '') || coalesce(pg_get_expr(polwithcheck, polrelid), '')) ilike '%deleted_at%'),
  'patient policies use is_deleted, not deleted_at');
set local enable_seqscan = off;
create temporary table t_plan (line text) on commit drop;
do $$
declare r record;
begin
  for r in execute $q$explain select id from patient.patients
           where tenant_id = '11111111-1111-4111-8111-111111111111' and not is_deleted
             and lower(last_name) = 'synthetic' and lower(first_name) = 'stamped'$q$ loop
    insert into t_plan values (r."QUERY PLAN");
  end loop;
end $$;
select tests.ok(exists (select 1 from t_plan where line like '%patients_tenant_name_idx%'),
  'a NOT is_deleted query (what EF emits) can use the partial name index');
reset enable_seqscan;
select set_config('request.jwt.claims', '{"sub":"0a000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

-- queue counters are stamped too
select tests.authenticate_as('reception@alpha.example');
select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-0000000000f1');
select tests.as_superuser();
select tests.ok(
  (select created_by = '0a000000-0000-4000-8000-000000000002' from appointment.queue_counters
   where branch_id = 'a1111111-0000-4000-8000-000000000001' and queue_date = identity.branch_local_date_v1(branch_id)),
  'queue_counters rows carry the audit columns, stamped with the real actor');

-- ================================================================ user_profiles log ==
select tests.authenticate_as('lab@alpha.example');
update identity.user_profiles set display_name = 'Alpha Lab Tech (renamed, synthetic)' where id = '0a000000-0000-4000-8000-000000000003';
select tests.as_superuser();
select tests.ok(
  exists (select 1 from audit.audit_log
          where schema_name = 'identity' and table_name = 'user_profiles' and action = 'UPDATE'
            and record_id = '0a000000-0000-4000-8000-000000000003' and tenant_id is null
            and changed_by = '0a000000-0000-4000-8000-000000000003'),
  'user_profiles changes are written to the audit log (tenant_id NULL = global row)');
select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  not exists (select 1 from audit.audit_log where table_name = 'user_profiles'),
  'tenant admins cannot read global (tenant_id NULL) audit rows');

rollback;
