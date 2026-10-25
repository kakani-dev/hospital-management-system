-- Uniform soft delete (migration 20261012090000, decision E7): branches, memberships,
-- practitioners, schedules. Admin-only, 404-not-403, restorable; a deleted membership grants nothing.
begin;

-- ======================================================================= memberships ==
select tests.as_superuser();
create temporary table t_ids on commit drop as
  select (select id from identity.memberships where user_id = '0a000000-0000-4000-8000-000000000002') as reception_m,
         (select id from identity.memberships where user_id = '0a000000-0000-4000-8000-000000000001') as admin_m,
         (select id from identity.memberships where user_id = '0b000000-0000-4000-8000-000000000002') as beta_doctor_m;
grant select on t_ids to public;

select tests.authenticate_as('reception@alpha.example');
select tests.ok((select count(*) from patient.patients) > 0, 'before: reception reads Alpha patients');
select tests.throws_ok(format($$select identity.soft_delete_membership(%L)$$, (select reception_m from t_ids)),
  '42501', 'non-admin cannot delete a membership (403)');

select tests.authenticate_as('admin@beta.example');
select tests.throws_ok(format($$select identity.soft_delete_membership(%L)$$, (select reception_m from t_ids)),
  'P0002', 'another tenant''s admin: membership looks unknown (404)');

select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(format($$select identity.soft_delete_membership(%L)$$, (select admin_m from t_ids)),
  '55000', 'the last admin cannot be removed');
select identity.soft_delete_membership((select reception_m from t_ids));
select tests.ok(
  (select is_deleted from identity.memberships where id = (select reception_m from t_ids)),
  'tenant_admin soft-deletes the reception membership (row kept)');
select tests.throws_ok(format($$select identity.soft_delete_membership(%L)$$, (select reception_m from t_ids)),
  'P0002', 'deleting it again -> 404');

select tests.authenticate_as('reception@alpha.example');
select tests.ok(not exists (select identity.current_tenant_ids()), 'deleted membership: no current tenant');
select tests.ok(not identity.has_tenant_role('11111111-1111-4111-8111-111111111111', array['receptionist']),
  'deleted membership: has_tenant_role is false');
select tests.ok(not identity.can_access_branch('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001'),
  'deleted membership: no branch access');
select tests.ok((select count(*) from patient.patients) = 0, 'deleted membership: zero patient rows visible (RLS)');
select tests.ok(not exists (select * from identity.my_memberships()), 'deleted membership: my_memberships() is empty');
select tests.ok(not exists (select * from identity.memberships), 'the deleted membership is hidden from its own user');
select tests.throws_ok(
  $$select identity.set_active_context('11111111-1111-4111-8111-111111111111')$$, '42501',
  'deleted membership: cannot switch into the tenant');
select tests.as_superuser();
set local role supabase_auth_admin;
select tests.ok(
  (identity.custom_access_token_hook('{"user_id":"0a000000-0000-4000-8000-000000000002","claims":{}}'::jsonb) -> 'claims' ->> 'tenant_id') is null,
  'deleted membership: the access-token hook issues no tenant claim');
select tests.as_superuser();

select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  exists (select 1 from identity.memberships where id = (select reception_m from t_ids) and is_deleted),
  'admins still see the deleted membership (to restore it)');
select tests.ok(
  tests.affected_rows(format($$update identity.memberships set role = 'nurse' where id = %L$$, (select reception_m from t_ids))) = 0,
  'a deleted membership cannot be edited (UPDATE policy hides it)');
-- re-inviting creates a NEW invitation (the deleted row does not block the unique key)
select tests.ok(
  identity.add_member('11111111-1111-4111-8111-111111111111', 'reception@alpha.example', 'receptionist', 'a1111111-0000-4000-8000-000000000001')
    is distinct from (select reception_m from t_ids),
  're-inviting after delete creates a new membership (partial unique key)');
select tests.throws_ok(format($$select identity.restore_membership(%L)$$, (select reception_m from t_ids)),
  '23505', 'restoring while a live duplicate exists -> 23505');
select tests.as_superuser();
delete from identity.memberships where user_id = '0a000000-0000-4000-8000-000000000002' and status = 'invited';
select tests.authenticate_as('admin@alpha.example');
select identity.restore_membership((select reception_m from t_ids));
select tests.throws_ok(format($$select identity.restore_membership(%L)$$, (select reception_m from t_ids)),
  'P0002', 'restoring a live membership -> 404');
select tests.authenticate_as('reception@alpha.example');
select tests.ok((select count(*) from patient.patients) > 0, 'after restore: reception reads Alpha patients again');

-- ========================================================================= branches ==
select tests.authenticate_as('admin@beta.example');
select tests.throws_ok($$select identity.soft_delete_branch('b2222222-0000-4000-8000-000000000001')$$,
  '55000', 'the last branch of a hospital cannot be deleted');
select tests.throws_ok($$select identity.soft_delete_branch('a1111111-0000-4000-8000-000000000002')$$,
  'P0002', 'another tenant''s branch looks unknown (404)');
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok($$select identity.soft_delete_branch('a1111111-0000-4000-8000-000000000002')$$,
  '42501', 'non-admin cannot delete a branch (403)');
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$select identity.soft_delete_branch('a1111111-0000-4000-8000-000000000001')$$,
  '55000', 'a branch with open appointments cannot be deleted');
select identity.soft_delete_branch('a1111111-0000-4000-8000-000000000002');
select tests.ok(
  (select is_deleted and not is_active from identity.branches where id = 'a1111111-0000-4000-8000-000000000002'),
  'tenant_admin soft-deletes Alpha East (also deactivated)');
select tests.ok(
  not exists (select 1 from identity.my_active_context() c where 'a1111111-0000-4000-8000-000000000002'::uuid = any (c.branch_ids)),
  'a deleted branch drops out of the active context');
select tests.authenticate_as('consultant@shared.example', '{"tenant_id":"11111111-1111-4111-8111-111111111111"}');
select tests.ok(not identity.can_access_branch('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002'),
  'members of a deleted branch lose access to it');
select tests.authenticate_as('reception@alpha.example');
select tests.ok(not exists (select 1 from identity.branches where id = 'a1111111-0000-4000-8000-000000000002'),
  'non-admins no longer see the deleted branch');
select tests.throws_ok(
  $$select * from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', '2030-01-07', '2030-01-07')$$,
  'P0002', 'slots at a deleted branch -> 404');
select tests.authenticate_as('admin@alpha.example');
insert into identity.branches (tenant_id, code, name) values ('11111111-1111-4111-8111-111111111111', 'east', 'New East (synthetic)');
select tests.ok(true, 'the code of a deleted branch can be reused (partial unique key)');
select tests.throws_ok($$select identity.restore_branch('a1111111-0000-4000-8000-000000000002')$$,
  '23505', 'restoring into a reused code -> 23505');
select tests.as_superuser();
delete from identity.branches where code = 'east' and not is_deleted and tenant_id = '11111111-1111-4111-8111-111111111111';
select tests.authenticate_as('admin@alpha.example');
select identity.restore_branch('a1111111-0000-4000-8000-000000000002');
select tests.ok(
  (select not is_deleted and not is_active from identity.branches where id = 'a1111111-0000-4000-8000-000000000002'),
  'restored branch comes back inactive (admin re-activates explicitly)');

-- ==================================================================== practitioners ==
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$select appointment.soft_delete_practitioner('c2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'another tenant''s practitioner looks unknown (404)');
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok($$select appointment.soft_delete_practitioner('c1111111-0000-4000-8000-000000000001')$$,
  '42501', 'non-admin cannot delete a practitioner (403)');
select tests.authenticate_as('admin@alpha.example');
select appointment.soft_delete_practitioner('c1111111-0000-4000-8000-000000000001');
select tests.authenticate_as('reception@alpha.example');
select tests.ok(not exists (select 1 from appointment.practitioners where id = 'c1111111-0000-4000-8000-000000000001'),
  'non-admins no longer see the deleted practitioner');
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
    values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000001',
            'aa000000-0000-4000-8000-000000000002', '2030-02-04 10:00+05:30', '2030-02-04 10:15+05:30')$$,
  'P0002', 'a deleted practitioner cannot be booked (404)');
select appointment.restore_practitioner('c1111111-0000-4000-8000-000000000001');
select tests.ok(
  (select not is_deleted and not is_active from appointment.practitioners where id = 'c1111111-0000-4000-8000-000000000001'),
  'restored practitioner comes back inactive');

-- ======================================================================== schedules ==
select tests.authenticate_as('admin@beta.example');
select tests.throws_ok($$select appointment.restore_schedule('d1111111-0000-4000-8000-000000000003')$$,
  'P0002', 'another tenant''s schedule looks unknown on restore (404)');
select tests.authenticate_as('admin@alpha.example');
select appointment.soft_delete_schedule('d1111111-0000-4000-8000-000000000003');
select tests.ok(
  not exists (select 1 from appointment.available_slots('11111111-1111-4111-8111-111111111111',
                'a1111111-0000-4000-8000-000000000001', '2030-01-14', '2030-01-14', 'c1111111-0000-4000-8000-000000000002')),
  'a deleted schedule produces no slots');
insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000001',
        1, '11:00', '12:00', 20, '2026-01-01');
select tests.ok(true, 'a deleted schedule no longer blocks an overlapping new one');
select tests.throws_ok($$select appointment.restore_schedule('d1111111-0000-4000-8000-000000000003')$$,
  '23P01', 'restoring into an overlap -> 23P01');
select tests.throws_ok($$delete from appointment.schedules where id = 'd1111111-0000-4000-8000-000000000004'$$,
  '42501', 'hard DELETE of schedules is not granted');
select tests.throws_ok(
  format($$delete from identity.memberships where id = %L$$, (select beta_doctor_m from t_ids)),
  '42501', 'hard DELETE of memberships is not granted');

-- ================================================ review S11: branch_ids + restore collisions ==
select tests.as_superuser();
insert into identity.branches (id, tenant_id, code, name)
values ('a1111111-0000-4000-8000-0000000000c1', '11111111-1111-4111-8111-111111111111', 'reuse', 'Reuse (synthetic)');
select tests.authenticate_as('admin@alpha.example');
select tests.ok('a1111111-0000-4000-8000-0000000000c1' = any (array(select identity.current_branch_ids('11111111-1111-4111-8111-111111111111'))),
  'a live branch is in current_branch_ids()');
select identity.soft_delete_branch('a1111111-0000-4000-8000-0000000000c1');
select tests.ok(not ('a1111111-0000-4000-8000-0000000000c1' = any (array(select identity.current_branch_ids('11111111-1111-4111-8111-111111111111')))),
  'a soft-deleted branch disappears from current_branch_ids()');
insert into identity.branches (tenant_id, code, name) values ('11111111-1111-4111-8111-111111111111', 'reuse', 'Reuse again (synthetic)');
select tests.ok(true, 'the code of a deleted branch can be reused');
select tests.throws_ok($$select identity.restore_branch('a1111111-0000-4000-8000-0000000000c1')$$,
  '23505', 'restoring a branch whose code was reused -> 23505');

select tests.as_superuser();
insert into identity.memberships (id, tenant_id, user_id, branch_id, role, status)
values ('cc000000-0000-4000-8000-0000000000c1', '11111111-1111-4111-8111-111111111111',
        '0c000000-0000-4000-8000-000000000001', null, 'viewer', 'active');
select tests.authenticate_as('admin@alpha.example');
select identity.soft_delete_membership('cc000000-0000-4000-8000-0000000000c1');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status)
values ('11111111-1111-4111-8111-111111111111', '0c000000-0000-4000-8000-000000000001', null, 'billing', 'invited');
select tests.throws_ok($$select identity.restore_membership('cc000000-0000-4000-8000-0000000000c1')$$,
  '23505', 'restoring a membership for a user who was re-added -> 23505');

-- ============================== re-review R2: patients' deleted_at is guarded (generated is_deleted) ==
select tests.as_superuser();
set local role service_role;
select tests.throws_ok(
  $$update patient.patients set deleted_at = now() where id = 'aa000000-0000-4000-8000-000000000001'$$,
  '42501', 'R2: service_role cannot soft-delete a patient by writing deleted_at (skips the open-visits check)');
select tests.throws_ok(
  $$update patient.patients set is_deleted = true where id = 'aa000000-0000-4000-8000-000000000001'$$,
  '428C9', 'R2: the generated is_deleted itself cannot be written');
select tests.ok(
  tests.affected_rows($$update patient.patients set first_name = first_name where id = 'aa000000-0000-4000-8000-000000000001'$$) = 1,
  'R2: other patient columns stay writable for service_role (only the soft-delete state is guarded)');
reset role;
select tests.authenticate_as('admin@alpha.example');
select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000004', 'synthetic R2');
select tests.as_superuser();
select tests.ok((select is_deleted and deleted_by is not null from patient.patients where id = 'aa000000-0000-4000-8000-000000000004'),
  'R2: the SECURITY DEFINER soft_delete_patient (owner) still soft-deletes, with deleted_by');
set local role service_role;
select tests.throws_ok(
  $$update patient.patients set deleted_at = null where id = 'aa000000-0000-4000-8000-000000000004'$$,
  '42501', 'R2: service_role cannot restore a patient by clearing deleted_at');
reset role;

rollback;
