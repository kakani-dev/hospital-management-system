-- Role-based and branch-scoped access inside a single tenant.
begin;

-- Receptionist is limited to Alpha Main Campus for writes
select tests.authenticate_as('reception@alpha.example');
select tests.ok((select count(*) from patient.patients) = 4, 'receptionist can read the Alpha registry');
select tests.ok(
  (select array_agg(b order by b) from identity.current_branch_ids('11111111-1111-4111-8111-111111111111') b)
    = array['a1111111-0000-4000-8000-000000000001'::uuid],
  'receptionist branch scope is Alpha Main only');
select tests.ok(
  tests.affected_rows($$insert into patient.patients (tenant_id, registered_branch_id, first_name, last_name)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'New', 'Synthetic-Alpha')$$) = 1,
  'receptionist can register a patient at their own branch');
select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, first_name, last_name)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'Other', 'Synthetic-Alpha')$$,
  '42501', 'receptionist cannot register a patient at a branch they are not assigned to');
select tests.throws_ok(
  $$insert into identity.branches (tenant_id, code, name) values ('11111111-1111-4111-8111-111111111111', 'west', 'West')$$,
  '42501', 'receptionist cannot create branches');
select tests.throws_ok(
  $$insert into identity.memberships (tenant_id, user_id, role)
    values ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-000000000002', 'tenant_admin')$$,
  '42501', 'receptionist cannot escalate to tenant_admin');
select tests.ok((select count(*) from identity.memberships) = 1, 'receptionist only sees their own membership');
select tests.ok((select count(*) from audit.audit_log) = 0, 'receptionist cannot read the audit log');
select tests.throws_ok(
  $$update identity.tenants set code = 'renamed' where id = '11111111-1111-4111-8111-111111111111'$$,
  '42501', 'tenant code is not updatable by authenticated users (column grant)');

-- Lab technician: no registry access yet (least privilege)
select tests.authenticate_as('lab@alpha.example');
select tests.ok((select count(*) from patient.patients) = 0, 'lab technician has no patient registry access');

-- Tenant admin can manage own tenant
select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  tests.affected_rows($$insert into identity.branches (tenant_id, code, name) values ('11111111-1111-4111-8111-111111111111', 'west', 'Alpha West')$$) = 1,
  'tenant admin can create a branch in own tenant');
select tests.throws_ok(
  $$insert into identity.branches (tenant_id, code, name) values ('22222222-2222-4222-8222-222222222222', 'evil', 'Evil')$$,
  '42501', 'tenant admin cannot create a branch in another tenant');
select tests.ok(
  tests.affected_rows($$update identity.tenants set name = 'Demo Alpha Hospital (synthetic, renamed)' where id = '11111111-1111-4111-8111-111111111111'$$) = 1,
  'tenant admin can rename own tenant');
select tests.ok((select count(*) from identity.memberships) = 4, 'tenant admin sees all 4 Alpha memberships');

-- Consultant: doctor in Alpha (East branch only)
select tests.authenticate_as('consultant@shared.example', '{"app_metadata": {"tenant_id": "11111111-1111-4111-8111-111111111111"}}');
-- RBAC (20261020090000): doctors are view-only on patients, so the row is not even updatable
select tests.ok(
  tests.affected_rows($$update patient.patients set registered_branch_id = 'a1111111-0000-4000-8000-000000000001' where id = 'aa000000-0000-4000-8000-000000000003'$$) = 0,
  'doctor cannot move (or edit) a patient');

rollback;
