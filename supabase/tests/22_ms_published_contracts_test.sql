-- Microservices: published, versioned cross-schema contracts.
-- Migration 20261013090000_ms_published_contracts.sql (DB review B2/B4) on top of the audit-tz
-- v1 surface (20261012090000 / 20261012090100); docs/contracts/db.md.
begin;

select tests.as_superuser();

-- ---------- identity.my_tenant_grant_v1 ----------
select tests.ok(
  has_function_privilege('authenticated', 'identity.my_tenant_grant_v1(uuid)', 'execute')
  and not has_function_privilege('anon', 'identity.my_tenant_grant_v1(uuid)', 'execute'),
  'my_tenant_grant_v1: authenticated may execute, anon may not');

select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  identity.my_tenant_grant_v1('11111111-1111-4111-8111-111111111111')
    -> 'memberships' = '[{"role": "receptionist", "branch_id": "a1111111-0000-4000-8000-000000000001"}]'::jsonb,
  'receptionist sees exactly their own active branch membership');
select tests.ok(
  jsonb_array_length(identity.my_tenant_grant_v1('11111111-1111-4111-8111-111111111111') -> 'branches') = 2
  and identity.my_tenant_grant_v1('11111111-1111-4111-8111-111111111111') -> 'branches' @> '[{"id": "a1111111-0000-4000-8000-000000000001", "timezone": "Asia/Kolkata"}]'::jsonb,
  'grant document lists the tenant''s active branches with their time zones');
select tests.ok(
  coalesce(jsonb_array_length(identity.my_tenant_grant_v1('22222222-2222-4222-8222-222222222222') -> 'memberships'), 0) = 0,
  'no memberships in a tenant the caller does not belong to');

select tests.authenticate_as('consultant@shared.example');
select tests.ok(
  identity.my_tenant_grant_v1('22222222-2222-4222-8222-222222222222')
    -> 'memberships' = '[{"role": "doctor", "branch_id": null}]'::jsonb,
  'multi-tenant user: only the memberships of the REQUESTED tenant are returned');

select tests.authenticate_as('outsider@example.test');
select tests.ok(
  coalesce(jsonb_array_length(identity.my_tenant_grant_v1('11111111-1111-4111-8111-111111111111') -> 'memberships'), 0) = 0,
  'outsider gets no grant');

-- Suspended tenant -> null (same as the Sprint 1 EF store).
select tests.as_superuser();
update identity.tenants set status = 'suspended' where id = '22222222-2222-4222-8222-222222222222';
select tests.authenticate_as('admin@beta.example');
select tests.ok(
  identity.my_tenant_grant_v1('22222222-2222-4222-8222-222222222222') is null,
  'suspended tenant yields no grant document');
select tests.as_superuser();
update identity.tenants set status = 'active' where id = '22222222-2222-4222-8222-222222222222';

-- Invited (not yet accepted) membership grants nothing.
insert into auth.users (id, email, role, aud) values
  ('0a000000-0000-4000-8000-0000000000f6', 'invitee-16@alpha.example', 'authenticated', 'authenticated');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-0000000000f6', null, 'doctor', 'invited');
select tests.authenticate_as('invitee-16@alpha.example');
select tests.ok(
  coalesce(jsonb_array_length(identity.my_tenant_grant_v1('11111111-1111-4111-8111-111111111111') -> 'memberships'), 0) = 0,
  'invited membership grants nothing');

-- Soft-deleted membership grants nothing (audit-tz is_deleted).
select tests.as_owner('identity.memberships');
do $$
declare r uuid;
begin
  -- the is_deleted guard (re-review R1) only lets the TABLE OWNER that names the row
  -- (hms.soft_delete) change it; a non-owner superuser such as supabase_admin is refused
  for r in select m.id from identity.memberships m
           where m.user_id = (select id from auth.users where email = 'consultant@shared.example')
             and m.tenant_id = '22222222-2222-4222-8222-222222222222' loop
    perform set_config('hms.soft_delete', r::text, true);
    update identity.memberships set is_deleted = true where id = r;
  end loop;
  perform set_config('hms.soft_delete', '', true);
end
$$;
select tests.authenticate_as('consultant@shared.example');
select tests.ok(
  identity.my_tenant_grant_v1('22222222-2222-4222-8222-222222222222') is null,
  'a soft-deleted membership grants nothing');
select tests.as_owner('identity.memberships');
do $$
declare r uuid;
begin
  -- the is_deleted guard (re-review R1) only lets the TABLE OWNER that names the row
  -- (hms.soft_delete) change it; a non-owner superuser such as supabase_admin is refused
  for r in select m.id from identity.memberships m
           where m.user_id = (select id from auth.users where email = 'consultant@shared.example')
             and m.tenant_id = '22222222-2222-4222-8222-222222222222' loop
    perform set_config('hms.soft_delete', r::text, true);
    update identity.memberships set is_deleted = false where id = r;
  end loop;
  perform set_config('hms.soft_delete', '', true);
end
$$;

-- Branch without an override inherits the tenant zone (audit-tz tenant time zone).
-- zone writes: as the table owner (R5 refuses non-owner writers such as supabase_admin when bookings exist)
select tests.as_owner('identity.branches');
update identity.branches set timezone_override = null where id = 'a1111111-0000-4000-8000-000000000001';
update identity.tenants set time_zone = 'Asia/Dubai' where id = '11111111-1111-4111-8111-111111111111';
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  identity.my_tenant_grant_v1('11111111-1111-4111-8111-111111111111') -> 'branches'
    @> '[{"id": "a1111111-0000-4000-8000-000000000001", "timezone": "Asia/Dubai"}]'::jsonb,
  'branches list the EFFECTIVE zone (tenant zone when the branch has no override)');
select tests.ok(
  identity.my_tenant_grant_v1('11111111-1111-4111-8111-111111111111') ->> 'tenant_time_zone' = 'Asia/Dubai',
  'grant document carries the tenant zone');
select tests.as_owner('identity.tenants');
update identity.tenants set time_zone = 'Asia/Kolkata' where id = '11111111-1111-4111-8111-111111111111';
update identity.branches set timezone = 'Asia/Kolkata' where id = 'a1111111-0000-4000-8000-000000000001';
select tests.as_superuser();

-- ---------- every published _v1 object: definer, pinned search_path, exact signature ----------
-- The full v1 surface after the split: audit-tz's functions + the ones added for the services.
select tests.as_superuser();
select tests.ok(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where p.prosecdef and coalesce(p.proconfig @> array['search_path=""'], false)
      and (n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')') in (
        'identity.my_tenant_grant_v1(p_tenant_id uuid)',
        'identity.branch_exists_v1(p_tenant_id uuid, p_branch_id uuid)',
        'identity.branch_tenant_id_v1(p_branch_id uuid)',
        'identity.branch_time_zone_v1(p_branch_id uuid)',
        'identity.branch_local_date_v1(p_branch_id uuid, p_at timestamp with time zone)',
        'patient.patient_summary_v1(p_tenant_id uuid, p_patient_ids uuid[])',
        'patient.patient_exists_v1(p_tenant_id uuid, p_patient_id uuid)',
        'appointment.patient_has_open_visits_v1(p_tenant_id uuid, p_patient_id uuid)',
        'appointment.patient_has_active_visits_v1(p_tenant_id uuid, p_patient_id uuid)',
        'appointment.branch_has_open_activity_v1(p_tenant_id uuid, p_branch_id uuid)',
        'appointment.queue_has_entries_v1(p_tenant_id uuid, p_branch_ids uuid[], p_days date[])')) = 11,
  'all 11 published _v1 functions exist with their exact signatures, SECURITY DEFINER, search_path pinned');
select tests.ok(
  not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where c.relkind = 'v' and n.nspname in ('identity', 'patient', 'appointment', 'messaging')
                and c.relname like '%\_v_' escape '\'),
  'no published views (B4: functions only, never definer or cross-service invoker views)');
select tests.ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('identity', 'patient', 'appointment') and p.proname like '%\_v1' escape '\'
      and has_function_privilege('anon', p.oid, 'execute'))
  and has_function_privilege('authenticated', 'patient.patient_summary_v1(uuid, uuid[])', 'execute')
  and has_function_privilege('authenticated', 'identity.my_tenant_grant_v1(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'appointment.patient_has_open_visits_v1(uuid, uuid)', 'execute'),
  'no _v1 function is callable by anon; my_tenant_grant_v1 and patient_summary_v1 are authenticated (explicit tenant checks); patient_has_open_visits_v1 is service-only (R6)');

-- ---------- patient.patient_summary_v1 ----------
select tests.ok(
  (select array_agg(a order by o) from unnest(
     (select proargnames from pg_proc where oid = 'patient.patient_summary_v1(uuid, uuid[])'::regprocedure)) with ordinality t(a, o)
   where o > 2) = array['id', 'tenant_id', 'mrn', 'first_name', 'last_name', 'is_deleted'],
  'patient_summary_v1 returns exactly the v1 columns (no phone, email, DOB)');

select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  (select count(*) from patient.patient_summary_v1('11111111-1111-4111-8111-111111111111',
     array['aa000000-0000-4000-8000-000000000001', 'bb000000-0000-4000-8000-000000000001']::uuid[])) = 1,
  'own tenant: only that tenant''s ids come back (a foreign id in the list is ignored)');
select tests.ok(
  (select count(*) from patient.patient_summary_v1('22222222-2222-4222-8222-222222222222',
     array['bb000000-0000-4000-8000-000000000001']::uuid[])) = 0,
  'foreign tenant: nothing, even with a valid id of that tenant');
select tests.authenticate_as('lab@alpha.example');
select tests.ok(
  (select count(*) from patient.patient_summary_v1('11111111-1111-4111-8111-111111111111',
     array['aa000000-0000-4000-8000-000000000001']::uuid[])) = 0,
  'a role without registry/appointment read (lab) gets nothing');
select tests.throws_ok(
  $$select * from patient.patient_summary_v1('11111111-1111-4111-8111-111111111111', array_fill(gen_random_uuid(), array[501]))$$,
  '22023', 'more than 500 ids is rejected');

select tests.as_owner('patient.patients');  -- R1/R2: only the owner naming the row may flip deleted_at
select set_config('hms.soft_delete', 'aa000000-0000-4000-8000-000000000002', true);
update patient.patients set deleted_at = now() where id = 'aa000000-0000-4000-8000-000000000002';
select set_config('hms.soft_delete', '', true);
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  (select is_deleted from patient.patient_summary_v1('11111111-1111-4111-8111-111111111111',
     array['aa000000-0000-4000-8000-000000000002']::uuid[])) is true,
  'soft-deleted patients are included (is_deleted = true) so appointment history keeps a name');
select tests.as_owner('patient.patients');  -- R1/R2: only the owner naming the row may flip deleted_at
select set_config('hms.soft_delete', 'aa000000-0000-4000-8000-000000000002', true);
update patient.patients set deleted_at = null where id = 'aa000000-0000-4000-8000-000000000002';
select set_config('hms.soft_delete', '', true);

-- ---------- identity.branch_time_zone_v1 ----------
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  identity.branch_time_zone_v1('a1111111-0000-4000-8000-000000000001') = 'Asia/Kolkata',
  'branch_time_zone_v1 returns the zone of an own-tenant branch');
select tests.throws_ok(
  $$select identity.branch_time_zone_v1('b2222222-0000-4000-8000-000000000001')$$, 'P0002',
  'branch_time_zone_v1 raises P0002 for another tenant''s branch');

-- ---------- appointment.patient_has_open_visits_v1 ----------
select tests.as_superuser();
select tests.ok(
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'patient' and p.proname = 'soft_delete_patient'
                and (pg_get_functiondef(p.oid) ~ 'appointment\.(appointments|queue_entries)'
                     or pg_get_functiondef(p.oid) !~ 'appointment\.patient_has_open_visits_v1\(')),
  'patient.soft_delete_patient asks the canonical appointment.patient_has_open_visits_v1, never the tables');
select tests.ok(
  pg_get_functiondef('appointment.patient_has_active_visits_v1(uuid, uuid)'::regprocedure)
    ~ 'appointment\.patient_has_open_visits_v1\(',
  'the deprecated audit-tz name delegates to the canonical function');

create temporary table t_ctx on commit drop as
  select (now() at time zone z.tz)::date + 3 as day, z.tz
  from (select identity.branch_time_zone_v1('a1111111-0000-4000-8000-000000000001') as tz) z;
grant select on t_ctx to public;
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
select 'e1111111-0000-4000-8000-0000000000f1', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001',
       'c1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000003',
       (day + time '09:00') at time zone tz, (day + time '09:15') at time zone tz from t_ctx;
select tests.ok(
  appointment.patient_has_open_visits_v1('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000003')
  and not appointment.patient_has_open_visits_v1('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-0000000000ff'),
  'patient_has_open_visits_v1 detects a booked appointment');
select tests.ok(
  appointment.patient_has_active_visits_v1('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000003'),
  'the deprecated alias gives the same answer');
select tests.ok(
  appointment.branch_has_open_activity_v1('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001')
  and not appointment.branch_has_open_activity_v1('22222222-2222-4222-8222-222222222222', 'a1111111-0000-4000-8000-000000000001'),
  'branch_has_open_activity_v1 sees the booked appointment, tenant-scoped');

select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(
  $$select patient.soft_delete_patient('aa000000-0000-4000-8000-000000000003')$$, '55000',
  'soft delete is still refused with 55000 while the patient has an open appointment');
select tests.authenticate_as('admin@beta.example');
select tests.throws_ok(
  $$select appointment.patient_has_open_visits_v1('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000003')$$,
  '42501', 'R6: patient_has_open_visits_v1 is not executable by signed-in members (service_role only)');
select tests.as_superuser();
select tests.ok(
  not has_function_privilege('authenticated', 'appointment.patient_has_open_visits_v1(uuid,uuid)', 'execute')
  and not has_function_privilege('authenticated', 'appointment.patient_has_active_visits_v1(uuid,uuid)', 'execute')
  and has_function_privilege('service_role', 'appointment.patient_has_open_visits_v1(uuid,uuid)', 'execute'),
  'R6: open-visit functions: service_role yes, authenticated no');

-- R4 on the functions added here: an authenticated session WITHOUT a sub claim gets nothing.
grant execute on function appointment.patient_has_open_visits_v1(uuid, uuid) to authenticated;  -- rolled back
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
set local role authenticated;
select tests.throws_ok(
  $$select appointment.patient_has_open_visits_v1('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000003')$$,
  'P0002', 'R4: no-sub authenticated -> patient_has_open_visits_v1 P0002');
select tests.ok(
  (select count(*) from patient.patient_summary_v1('11111111-1111-4111-8111-111111111111', array['aa000000-0000-4000-8000-000000000003'::uuid])) = 0,
  'R4: no-sub authenticated -> patient_summary_v1 returns nothing');
select tests.ok(identity.my_tenant_grant_v1('11111111-1111-4111-8111-111111111111') is null,
  'R4: no-sub authenticated -> my_tenant_grant_v1 null');
select tests.as_superuser();

-- MAJ-2: a branch-scoped membership at a soft-deleted branch grants nothing.
-- (guard triggers bypassed for this rolled-back transaction: only the read side is under test here)
set local session_replication_role = replica;
update identity.branches set is_deleted = true where id = 'a1111111-0000-4000-8000-000000000001';
set local session_replication_role = origin;
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  identity.my_tenant_grant_v1('11111111-1111-4111-8111-111111111111') is null
  or coalesce(jsonb_array_length(identity.my_tenant_grant_v1('11111111-1111-4111-8111-111111111111') -> 'memberships'), 0) = 0,
  'MAJ-2: a membership at a deleted branch grants nothing');
select tests.as_superuser();


rollback;
