-- RBAC (ADR 0001, 20261020090000): the role -> permission matrix is mirrored in RLS.
begin;
select tests.as_superuser();

select tests.ok((select count(*) from identity.role_permissions where role = 'tenant_admin') = 29, 'tenant_admin holds all 29 tenant permissions (billing adds eight)');
select tests.ok(not exists (select 1 from identity.role_permissions where role in ('viewer', 'pharmacist', 'lab_technician')
                            and permission not in ('settings.view', 'branches.view', 'practitioners.view')),
  'viewer / pharmacist / lab_technician are read-only and see no patient data');
select tests.ok(not exists (select 1 from identity.role_permissions where role in ('doctor', 'nurse', 'billing')
                            and permission in ('patients.create', 'patients.edit', 'patients.delete')),
  'doctor / nurse / billing cannot create or edit patients');
select tests.ok(not exists (select 1 from identity.role_permissions where role in ('doctor', 'billing') and permission = 'appointments.book'),
  'doctor / billing cannot book freely (nurses can since 20261020140000; doctors only own follow-ups)');
select tests.ok(not exists (select 1 from identity.role_permissions where permission like 'platform.%'), 'no tenant role grants platform permissions');

-- receptionist (Alpha Main)
select tests.authenticate_as('reception@alpha.example');
select tests.ok(identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'patients.create'), 'receptionist may create patients');
select tests.ok(identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'billing.bill')
                and identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'billing.discount_request')
                and not identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'billing.approve')
                and not identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'billing.refund'),
  'receptionist can bill and request a discount, and cannot approve or refund');
select tests.ok(not identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'members.manage'), 'receptionist may not manage members');
select tests.ok(not identity.has_tenant_permission('22222222-2222-4222-8222-222222222222', 'patients.view'), 'no permission in a tenant without membership');
select tests.ok(tests.affected_rows($$update patient.patients set first_name = first_name where id = 'aa000000-0000-4000-8000-000000000001'$$) = 1,
  'receptionist can edit a patient at their branch (RLS)');

-- doctor (Beta, tenant-wide)
select tests.authenticate_as('doctor@beta.example');
select tests.ok(identity.has_tenant_permission('22222222-2222-4222-8222-222222222222', 'patients.view'), 'doctor may view patients');
select tests.ok((select count(*) from patient.patients where tenant_id = '22222222-2222-4222-8222-222222222222') > 0, 'doctor reads patients (RLS)');
select tests.ok(tests.affected_rows($$update patient.patients set first_name = first_name where tenant_id = '22222222-2222-4222-8222-222222222222'$$) = 0,
  'doctor cannot edit patients (RLS)');
select tests.throws_ok($$select patient.set_patient_phones('bb000000-0000-4000-8000-000000000001', null, false, null)$$,
  '42501', 'doctor cannot change patient phones');

-- lab technician (Alpha, tenant-wide)
select tests.authenticate_as('lab@alpha.example');
select tests.ok((select count(*) from patient.patients) = 0, 'lab technician sees no patients (RLS)');
select tests.ok(identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'branches.view')
                and not identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'appointments.view'),
  'lab technician: branches read-only, no appointments');

-- tenant admin
select tests.authenticate_as('admin@alpha.example');
select tests.ok(identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'members.manage'), 'tenant_admin manages members');
select tests.ok(not identity.has_tenant_permission('11111111-1111-4111-8111-111111111111', 'platform.console'), 'unknown permission is denied');

rollback;
