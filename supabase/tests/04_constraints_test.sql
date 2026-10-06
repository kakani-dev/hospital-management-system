-- Tenant-scoped constraints (run as the migration owner, i.e. bypassing RLS,
-- to prove the database itself enforces them even for privileged code paths).
begin;
select tests.as_superuser();

select tests.ok(
  (select count(*) from patient.patients where mrn = 'MRN-1001') = 2,
  'the same MRN exists in two tenants (tenant-scoped uniqueness)');
select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, mrn, first_name, last_name)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'MRN-1001', 'Dup', 'Synthetic-Alpha')$$,
  '23505', 'duplicate MRN inside one tenant is rejected');
select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, mrn, first_name, last_name)
    values ('11111111-1111-4111-8111-111111111111', 'b2222222-0000-4000-8000-000000000001', 'ALP-7777', 'Cross', 'Branch')$$,
  '23503', 'patient cannot reference a branch owned by another tenant (composite FK)');
select tests.throws_ok(
  $$insert into identity.memberships (tenant_id, user_id, branch_id, role)
    values ('22222222-2222-4222-8222-222222222222', '0c000000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000001', 'viewer')$$,
  '23503', 'membership cannot reference a branch owned by another tenant (composite FK)');
select tests.throws_ok(
  $$update patient.patients set tenant_id = '22222222-2222-4222-8222-222222222222' where id = 'aa000000-0000-4000-8000-000000000002'$$,
  '42501', 'tenant_id is immutable even for privileged roles (trigger)');
select tests.throws_ok(
  $$insert into identity.branches (tenant_id, code, name) values ('11111111-1111-4111-8111-111111111111', 'main', 'Dup main')$$,
  '23505', 'duplicate branch code inside one tenant is rejected');
select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, mrn, first_name, last_name, sex)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'ALP-8888', 'Bad', 'Sex', 'x')$$,
  '23514', 'invalid sex value is rejected (check constraint)');

rollback;
