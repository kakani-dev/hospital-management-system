-- Audit trail: automatic, tenant-stamped, actor-stamped, append-only, tenant-isolated.
begin;

select tests.authenticate_as('reception@alpha.example');
insert into patient.patients (id, tenant_id, registered_branch_id, mrn, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000ff', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'ALP-5000', 'Audit', 'Synthetic-Alpha');
update patient.patients set phone = '+1-555-0199' where id = 'aa000000-0000-4000-8000-0000000000ff';

select tests.as_superuser();
select tests.ok(
  (select count(*) from audit.audit_log where record_id = 'aa000000-0000-4000-8000-0000000000ff') = 2,
  'insert + update produced 2 audit rows');
select tests.ok(
  (select bool_and(tenant_id = '11111111-1111-4111-8111-111111111111' and changed_by = '0a000000-0000-4000-8000-000000000002')
   from audit.audit_log where record_id = 'aa000000-0000-4000-8000-0000000000ff'),
  'audit rows carry the tenant_id and the authenticated actor');
select tests.ok(
  (select created_by = '0a000000-0000-4000-8000-000000000002' and updated_by = '0a000000-0000-4000-8000-000000000002'
   from patient.patients where id = 'aa000000-0000-4000-8000-0000000000ff'),
  'audit columns created_by/updated_by are stamped from auth.uid()');

select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  (select count(*) from audit.audit_log where record_id = 'aa000000-0000-4000-8000-0000000000ff') = 2,
  'alpha tenant admin can read Alpha audit rows');
select tests.ok(
  not exists (select 1 from audit.audit_log where tenant_id <> '11111111-1111-4111-8111-111111111111'),
  'alpha tenant admin sees no audit rows from other tenants');
select tests.throws_ok($$delete from audit.audit_log$$, '42501', 'authenticated users cannot delete audit rows');
select tests.throws_ok(
  $$insert into audit.audit_log (tenant_id, schema_name, table_name, action) values ('11111111-1111-4111-8111-111111111111', 'x', 'y', 'INSERT')$$,
  '42501', 'authenticated users cannot forge audit rows');

select tests.authenticate_as('admin@beta.example');
select tests.ok(
  not exists (select 1 from audit.audit_log where record_id = 'aa000000-0000-4000-8000-0000000000ff'),
  'beta tenant admin cannot read Alpha audit rows');

select tests.as_superuser();
select tests.throws_ok($$update audit.audit_log set action = 'DELETE'$$, '42501', 'audit log is append-only even for the owner (trigger)');
select tests.throws_ok($$truncate audit.audit_log$$, '42501', 'audit log cannot be truncated');

rollback;
