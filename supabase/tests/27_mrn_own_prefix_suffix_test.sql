-- Level 1 polish (20261019130000): only MRNs in the tenant's own '<PREFIX>-<digits>' format move the
-- MRN counter. Regression for SMOKE-20261009114530 inflating the Alpha counter.
begin;
select tests.as_superuser();

-- ------------------------------------------------------- the helper ----
select tests.ok(patient.mrn_own_suffix('DEMO-ALPHA-001234', 'DEMO-ALPHA') = 1234, 'own format -> its number');
select tests.ok(patient.mrn_own_suffix('demo-alpha-000007', 'DEMO-ALPHA') = 7, 'the prefix is compared case-insensitively');
select tests.ok(patient.mrn_own_suffix('DEMO-ALPHA-1000000', 'DEMO-ALPHA') = 1000000, 'numbers above 999999 count');
select tests.ok(patient.mrn_own_suffix('SMOKE-20261009114530', 'DEMO-ALPHA') is null, 'a foreign prefix (SMOKE-...) does not count');
select tests.ok(patient.mrn_own_suffix('MRN-1001', 'DEMO-ALPHA') is null and patient.mrn_own_suffix('ALP-0003', 'DEMO-ALPHA') is null,
  'legacy seed MRNs (MRN-1001, ALP-0003) do not count');
select tests.ok(patient.mrn_own_suffix('DEMO-ALPHA-X12', 'DEMO-ALPHA') is null
  and patient.mrn_own_suffix('DEMO-ALPHA-12-3', 'DEMO-ALPHA') is null
  and patient.mrn_own_suffix('DEMO-ALPHA-', 'DEMO-ALPHA') is null
  and patient.mrn_own_suffix('DEMO-ALPHA1234', 'DEMO-ALPHA') is null,
  'the part after "<PREFIX>-" must be digits only');
select tests.ok(patient.mrn_own_suffix('DEMO-ALPHA-000900', 'DEMO') is null,
  'a shorter tenant code does not claim a longer code''s MRNs (DEMO vs DEMO-ALPHA-...)');
select tests.ok(patient.mrn_own_suffix('XDEMO-ALPHA-000900', 'DEMO-ALPHA') is null, 'the prefix is anchored at the start');
select tests.ok(patient.mrn_own_suffix('DEMO-ALPHA-1234567890123456789', 'DEMO-ALPHA') is null, 'more than 18 digits never overflows (NULL)');
select tests.ok(patient.mrn_own_suffix(null, 'DEMO-ALPHA') is null and patient.mrn_own_suffix('DEMO-ALPHA-1', null) is null
  and patient.mrn_own_suffix('-1', '') is null, 'NULL / empty inputs -> NULL');
select tests.ok(patient.mrn_own_suffix('A.B-0042', 'A.B') = 42 and patient.mrn_own_suffix('AXB-0042', 'A.B') is null,
  'regex metacharacters in a code are literal');
select tests.ok(to_regprocedure('patient.mrn_numeric_suffix(text)') is null, 'the any-trailing-digits helper is gone');
select tests.ok(not has_function_privilege('authenticated', 'patient.mrn_own_suffix(text, text)', 'execute')
  and not has_function_privilege('anon', 'patient.mrn_own_suffix(text, text)', 'execute'),
  'clients cannot call mrn_own_suffix');

-- ------------------------------------------- privileged (owner) imports ----
select tests.ok((select last_value from patient.mrn_counters where tenant_id = '11111111-1111-4111-8111-111111111111') = 0,
  'seeded Alpha counter ignores the legacy seed MRNs');
insert into patient.patients (id, tenant_id, registered_branch_id, mrn, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000b1', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'SMOKE-20261009114530', 'Smoke', 'Legacy');
select tests.ok((select mrn from patient.patients where id = 'aa000000-0000-4000-8000-0000000000b1') = 'SMOKE-20261009114530'
  and (select last_value from patient.mrn_counters where tenant_id = '11111111-1111-4111-8111-111111111111') = 0,
  'an owner import of SMOKE-20261009114530 keeps the MRN but does not inflate the counter');
select tests.authenticate_as('reception@alpha.example');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000b2', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'After', 'Smoke');
select tests.as_superuser();
select tests.ok((select mrn from patient.patients where id = 'aa000000-0000-4000-8000-0000000000b2') = 'DEMO-ALPHA-000001',
  'the next generated MRN continues the tenant''s own sequence (not 20261009114531)');

insert into patient.patients (id, tenant_id, registered_branch_id, mrn, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000b3', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'demo-alpha-000040', 'Own', 'Import');
select tests.ok((select last_value from patient.mrn_counters where tenant_id = '11111111-1111-4111-8111-111111111111') = 40,
  'an owner import in the own format (any case) still moves the counter past it');
insert into patient.patients (id, tenant_id, registered_branch_id, mrn, first_name, last_name)
values ('aa000000-0000-4000-8000-0000000000b4', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'DEMO-BETA-009999', 'Other', 'Tenant');
select tests.ok((select last_value from patient.mrn_counters where tenant_id = '11111111-1111-4111-8111-111111111111') = 40
  and (select last_value from patient.mrn_counters where tenant_id = '22222222-2222-4222-8222-222222222222') = 0,
  'another tenant''s prefix moves neither counter');

-- a tenant whose code is a prefix of another tenant's code
insert into identity.tenants (id, code, name, time_zone) values ('33333333-3333-4333-8333-333333333333', 'demo', 'Demo (synthetic)', 'Asia/Kolkata');
insert into identity.branches (id, tenant_id, code, name) values ('c3333333-0000-4000-8000-000000000001', '33333333-3333-4333-8333-333333333333', 'main', 'Main');
insert into patient.patients (id, tenant_id, registered_branch_id, mrn, first_name, last_name)
values ('cc000000-0000-4000-8000-0000000000b1', '33333333-3333-4333-8333-333333333333', 'c3333333-0000-4000-8000-000000000001', 'DEMO-ALPHA-000900', 'Prefix', 'Overlap');
set local role service_role;
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('cc000000-0000-4000-8000-0000000000b2', '33333333-3333-4333-8333-333333333333', 'c3333333-0000-4000-8000-000000000001', 'First', 'Demo');
select tests.as_superuser();
select tests.ok((select mrn from patient.patients where id = 'cc000000-0000-4000-8000-0000000000b2') = 'DEMO-000001',
  'tenant "demo" is not advanced by an imported DEMO-ALPHA-000900');

-- ------------------------------------------------ counter re-seeding ----
-- the migration's data step: raise to the largest own-format MRN, never lower
update patient.mrn_counters set last_value = 3 where tenant_id = '11111111-1111-4111-8111-111111111111';
insert into patient.mrn_counters as c (tenant_id, last_value)
select p.tenant_id, max(patient.mrn_own_suffix(p.mrn, identity.tenant_mrn_prefix_v1(p.tenant_id)))
from patient.patients p group by p.tenant_id
having max(patient.mrn_own_suffix(p.mrn, identity.tenant_mrn_prefix_v1(p.tenant_id))) is not null
on conflict (tenant_id) do update set last_value = excluded.last_value where excluded.last_value > c.last_value;
select tests.ok((select last_value from patient.mrn_counters where tenant_id = '11111111-1111-4111-8111-111111111111') = 40,
  're-seeding raises a counter to the largest own-format MRN (SMOKE-... ignored)');
update patient.mrn_counters set last_value = 1001 where tenant_id = '11111111-1111-4111-8111-111111111111';
insert into patient.mrn_counters as c (tenant_id, last_value)
select p.tenant_id, max(patient.mrn_own_suffix(p.mrn, identity.tenant_mrn_prefix_v1(p.tenant_id)))
from patient.patients p group by p.tenant_id
having max(patient.mrn_own_suffix(p.mrn, identity.tenant_mrn_prefix_v1(p.tenant_id))) is not null
on conflict (tenant_id) do update set last_value = excluded.last_value where excluded.last_value > c.last_value;
select tests.ok((select last_value from patient.mrn_counters where tenant_id = '11111111-1111-4111-8111-111111111111') = 1001,
  're-seeding never lowers a counter (e.g. a manual reset to 1001 is kept)');

rollback;
