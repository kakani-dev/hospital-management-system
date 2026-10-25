-- Cross-tenant isolation using the two synthetic demo tenants (Alpha, Beta).
begin;

-- ---------- Alpha admin ----------
select tests.authenticate_as('admin@alpha.example');

select tests.ok((select count(*) from patient.patients) = 4, 'alpha admin sees exactly the 4 Alpha patients');
select tests.ok(
  not exists (select 1 from patient.patients where tenant_id = '22222222-2222-4222-8222-222222222222'),
  'alpha admin cannot read any Beta patient even when filtering by Beta tenant_id');
select tests.ok(
  not exists (select 1 from patient.patients where id = 'bb000000-0000-4000-8000-000000000001'),
  'alpha admin cannot read a Beta patient by primary key');
select tests.ok(
  (select count(*) from patient.patients where last_name ilike '%synthetic%') = 4,
  'search across all names only returns Alpha rows');
select tests.ok(
  (select count(*) from patient.patients where mrn = 'MRN-1001') = 1,
  'shared MRN lookup returns only the Alpha patient');
select tests.ok((select count(*) from identity.tenants) = 1, 'alpha admin sees only their own tenant');
select tests.ok(
  (select count(*) from identity.branches where tenant_id = '22222222-2222-4222-8222-222222222222') = 0,
  'alpha admin cannot see Beta branches');
select tests.ok(
  (select count(*) from identity.memberships where tenant_id = '22222222-2222-4222-8222-222222222222') = 0,
  'alpha admin cannot see Beta memberships');
select tests.ok(
  not exists (select 1 from identity.user_profiles where email = 'admin@beta.example'),
  'alpha admin cannot see profiles of Beta-only users');

select tests.ok(
  tests.affected_rows($$update patient.patients set first_name = 'Hacked' where tenant_id = '22222222-2222-4222-8222-222222222222'$$) = 0,
  'alpha admin UPDATE of Beta patients affects 0 rows');
select tests.ok(
  tests.affected_rows($$update identity.tenants set name = 'Hacked' where id = '22222222-2222-4222-8222-222222222222'$$) = 0,
  'alpha admin UPDATE of Beta tenant affects 0 rows');
select tests.throws_ok(
  $$delete from identity.branches where tenant_id = '22222222-2222-4222-8222-222222222222'$$,
  '42501', 'DELETE on branches is not granted at all (soft delete only); Beta branches stay untouched');

select tests.throws_ok(
  $$insert into patient.patients (tenant_id, registered_branch_id, mrn, first_name, last_name)
    values ('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'EVIL-1', 'Evil', 'Insert')$$,
  '42501', 'alpha admin cannot INSERT a patient into Beta (client-supplied tenant_id rejected)');
select tests.throws_ok(
  $$insert into identity.memberships (tenant_id, user_id, role)
    values ('22222222-2222-4222-8222-222222222222', '0a000000-0000-4000-8000-000000000001', 'tenant_admin')$$,
  '42501', 'alpha admin cannot grant themselves a membership in Beta (privilege escalation)');
select tests.throws_ok(
  $$update patient.patients set tenant_id = '22222222-2222-4222-8222-222222222222' where id = 'aa000000-0000-4000-8000-000000000001'$$,
  '42501', 'alpha admin cannot move an Alpha patient to Beta (tenant_id not updatable)');
select tests.throws_ok(
  $$delete from patient.patients where id = 'aa000000-0000-4000-8000-000000000001'$$,
  '42501', 'hard DELETE of patients is not permitted (soft delete only)');

-- ---------- Beta doctor ----------
select tests.authenticate_as('doctor@beta.example');
select tests.ok((select count(*) from patient.patients) = 1, 'beta doctor sees only the patient on their own visit');
select tests.ok(
  not exists (select 1 from patient.patients where tenant_id = '11111111-1111-4111-8111-111111111111'),
  'beta doctor cannot read Alpha patients');

-- ---------- Outsider (authenticated, no membership) ----------
select tests.authenticate_as('outsider@example.test');
select tests.ok((select count(*) from patient.patients) = 0, 'user without membership sees no patients');
select tests.ok((select count(*) from identity.tenants) = 0, 'user without membership sees no tenants');
select tests.ok((select count(*) from identity.current_tenant_ids()) = 0, 'current_tenant_ids() is empty for outsider');

-- ---------- Forged / pinned active-tenant claim ----------
select tests.authenticate_as('consultant@shared.example');
select tests.ok((select count(*) from identity.current_tenant_ids()) = 2, 'multi-tenant consultant has 2 tenants without a pin');
select tests.authenticate_as('consultant@shared.example', '{"app_metadata": {"tenant_id": "11111111-1111-4111-8111-111111111111"}}');
select tests.ok(
  (select count(*) from identity.current_tenant_ids()) = 1
  and not exists (select 1 from identity.current_tenant_ids() t where t <> '11111111-1111-4111-8111-111111111111')
  and (select count(*) from patient.patients) = 0
  and not exists (select 1 from patient.patients where tenant_id = '22222222-2222-4222-8222-222222222222'),
  'active-tenant claim pins the consultant to Alpha only (no own charts there)');
select tests.authenticate_as('outsider@example.test', '{"app_metadata": {"tenant_id": "11111111-1111-4111-8111-111111111111"}}');
select tests.ok((select count(*) from patient.patients) = 0,
  'a tenant claim without a real membership grants nothing (claims are intersected with memberships)');

-- ---------- Anonymous ----------
select tests.as_anon();
select tests.throws_ok($$select count(*) from patient.patients$$, '42501', 'anon has no access to patients');
select tests.throws_ok($$select count(*) from identity.tenants$$, '42501', 'anon has no access to tenants');

-- ---------- Suspended tenant ----------
select tests.as_superuser();
update identity.tenants set status = 'suspended' where id = '22222222-2222-4222-8222-222222222222';
select tests.authenticate_as('doctor@beta.example');
select tests.ok((select count(*) from patient.patients) = 0, 'members of a suspended tenant lose access');

rollback;
