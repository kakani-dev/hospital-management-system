-- Level 1: server-generated MRNs (migration 20261019100000). Per-tenant counter, TENANTCODE-000123,
-- client MRNs refused / ignored, immutable, seeded above the existing numeric suffixes.
-- The parallel-insert proof (many connections at once) is Hms.DatabaseTests.MrnConcurrencyTests.
begin;
select tests.as_superuser();

-- ------------------------------------------------------------ seeding ----
select tests.ok(
  (select last_value from patient.mrn_counters where tenant_id = '11111111-1111-4111-8111-111111111111') = 1001
  and (select last_value from patient.mrn_counters where tenant_id = '22222222-2222-4222-8222-222222222222') = 1001,
  'counters are seeded with the largest numeric suffix of existing MRNs (ALP-0003, MRN-1001 -> 1001)');
select tests.ok(
  (select bool_and(mrn in ('ALP-0001', 'ALP-0002', 'ALP-0003', 'MRN-1001', 'BET-0001', 'BET-0002'))
   from patient.patients where id::text like 'aa%' or id::text like 'bb%'),
  'existing patients keep their MRNs');
select tests.ok(
  (select created_by is not null and updated_by is not null and created_on is not null and not is_deleted
   from patient.mrn_counters where tenant_id = '11111111-1111-4111-8111-111111111111'),
  'mrn_counters carries the audit columns');

-- ----------------------------------------------------------- generation ----
select tests.authenticate_as('reception@alpha.example');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000a1', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'Gen', 'One');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000a2', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'Gen', 'Two');
select tests.ok(
  (select mrn from patient.patients where id = 'aa000000-0000-4000-8000-0000000000a1') = 'DEMO-ALPHA-001002'
  and (select mrn from patient.patients where id = 'aa000000-0000-4000-8000-0000000000a2') = 'DEMO-ALPHA-001003',
  'client inserts get <TENANT CODE>-<6 digits> from the tenant counter, in order');
select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, mrn, first_name, last_name)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'MY-OWN-1', 'Typed', 'Mrn')$$,
  '42501', 'a client cannot supply an MRN (no INSERT (mrn) privilege)');
select tests.throws_ok(
  $$update patient.patients set mrn = 'DEMO-ALPHA-999999' where id = 'aa000000-0000-4000-8000-0000000000a1'$$,
  '42501', 'a client cannot change an MRN (no UPDATE (mrn) privilege)');
select tests.throws_ok($$select * from patient.mrn_counters$$, '42501', 'clients cannot read the counters');
select tests.throws_ok($$update patient.mrn_counters set last_value = 0$$, '42501', 'clients cannot reset the counters');

select tests.authenticate_as('admin@beta.example');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('bb000000-0000-4000-8000-0000000000a1', '22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'Beta', 'Gen');
select tests.ok(
  (select mrn from patient.patients where id = 'bb000000-0000-4000-8000-0000000000a1') = 'DEMO-BETA-001002',
  'each tenant has its own counter (Beta is not advanced by Alpha inserts)');

-- service_role (PostgREST trusted writer) sending an MRN: ignored and replaced
select tests.as_superuser();
set local role service_role;
insert into patient.patients (id, tenant_id, registered_branch_id, mrn, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000a3', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'IGNORED-1', 'Svc', 'Role');
select tests.ok(
  (select mrn from patient.patients where id = 'aa000000-0000-4000-8000-0000000000a3') = 'DEMO-ALPHA-001004',
  'an MRN supplied by a non-owner role is ignored and generated');

-- ----------------------------------------------------- immutability ----
select tests.as_superuser();
select tests.throws_ok(
  $$update patient.patients set mrn = 'CHANGED-1' where id = 'aa000000-0000-4000-8000-000000000001'$$,
  '42501', 'the MRN is immutable even for the owner (trigger)');
select tests.ok(
  tests.affected_rows($$update patient.patients set first_name = first_name where id = 'aa000000-0000-4000-8000-000000000001'$$) = 1,
  'updates that do not touch the MRN still work');

-- -------------------------------------- explicit import (owner session) ----
insert into patient.patients (id, tenant_id, registered_branch_id, mrn, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000a4', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'DEMO-ALPHA-005000', 'Legacy', 'Import');
select tests.ok(
  (select last_value from patient.mrn_counters where tenant_id = '11111111-1111-4111-8111-111111111111') = 5000,
  'an owner import with an explicit MRN keeps it and moves the counter past its number');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000a5', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'After', 'Import');
select tests.ok(
  (select mrn from patient.patients where id = 'aa000000-0000-4000-8000-0000000000a5') = 'DEMO-ALPHA-005001',
  'the next generated MRN never collides with the imported one');
insert into patient.patients (id, tenant_id, registered_branch_id, mrn, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000a6', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'OLD-0007', 'Lower', 'Import');
select tests.ok(
  (select last_value from patient.mrn_counters where tenant_id = '11111111-1111-4111-8111-111111111111') = 5001,
  'an import with a smaller suffix never moves the counter backwards');

-- ------------------------------------------------- past 999999 / new tenant ----
update patient.mrn_counters set last_value = 999999 where tenant_id = '11111111-1111-4111-8111-111111111111';
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000a7', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'Big', 'Number');
select tests.ok(
  (select mrn from patient.patients where id = 'aa000000-0000-4000-8000-0000000000a7') = 'DEMO-ALPHA-1000000',
  'numbers above 999999 keep growing (never truncated)');

insert into identity.tenants (id, code, name, time_zone)
values ('33333333-3333-4333-8333-333333333333', 'gamma', 'Gamma (synthetic)', 'Asia/Kolkata');
insert into identity.branches (id, tenant_id, code, name)
values ('c3333333-0000-4000-8000-000000000001', '33333333-3333-4333-8333-333333333333', 'main', 'Main');
set local role service_role;
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('cc000000-0000-4000-8000-0000000000a1', '33333333-3333-4333-8333-333333333333', 'c3333333-0000-4000-8000-000000000001', 'First', 'Gamma');
select tests.ok(
  (select mrn from patient.patients where id = 'cc000000-0000-4000-8000-0000000000a1') = 'GAMMA-000001',
  'a new tenant starts at <CODE>-000001 (e.g. GAMMA-000001)');
select tests.as_superuser();

select tests.ok(
  (select relrowsecurity from pg_class where oid = 'patient.mrn_counters'::regclass)
  and not has_table_privilege('authenticated', 'patient.mrn_counters', 'select')
  and not has_table_privilege('anon', 'patient.mrn_counters', 'select'),
  'mrn_counters: RLS on, no client privileges');
select tests.ok(
  not has_function_privilege('authenticated', 'identity.tenant_mrn_prefix_v1(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'patient.assign_mrn()', 'execute'),
  'clients cannot call the MRN prefix / trigger functions');

rollback;
