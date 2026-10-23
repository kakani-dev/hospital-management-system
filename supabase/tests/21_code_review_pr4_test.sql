-- Code review of PR #4 (/workspace/review-pr4/REVIEW.md): MAJ-1 expand/contract of the branch zone,
-- MAJ-2 deleted branches revoke tenant-wide roles, MIN-1 DST-safe slots, MIN-2 POSIX suffixes.
begin;

-- ===================================== MAJ-1: branches.timezone stays the effective zone ==
select tests.as_superuser();
select tests.ok(
  (select bool_and(b.timezone = identity.branch_time_zone_v1(b.id)) from identity.branches b),
  'MAJ-1: for every branch the legacy column equals the effective zone');
insert into identity.branches (id, tenant_id, code, name, timezone) values
  ('a1111111-0000-4000-8000-0000000000e1', '11111111-1111-4111-8111-111111111111', 'leg-dxb', 'Legacy Dubai (synthetic)', 'Asia/Dubai'),
  ('a1111111-0000-4000-8000-0000000000e2', '11111111-1111-4111-8111-111111111111', 'leg-ist', 'Legacy IST (synthetic)', 'Asia/Calcutta');
insert into identity.branches (id, tenant_id, code, name, timezone_override) values
  ('a1111111-0000-4000-8000-0000000000e3', '11111111-1111-4111-8111-111111111111', 'new-utc', 'New UTC (synthetic)', 'UTC');
insert into identity.branches (id, tenant_id, code, name) values
  ('a1111111-0000-4000-8000-0000000000e4', '11111111-1111-4111-8111-111111111111', 'new-inh', 'New inheriting (synthetic)');
select tests.ok((select timezone_override = 'Asia/Dubai' and timezone = 'Asia/Dubai' from identity.branches where id = 'a1111111-0000-4000-8000-0000000000e1'),
  'MAJ-1: a legacy INSERT with a different zone becomes an override');
select tests.ok((select timezone_override is null and timezone = 'Asia/Kolkata' from identity.branches where id = 'a1111111-0000-4000-8000-0000000000e2'),
  'MAJ-1: a legacy INSERT with the tenant zone (even as an alias) inherits');
select tests.ok((select timezone_override = 'UTC' and timezone = 'UTC' from identity.branches where id = 'a1111111-0000-4000-8000-0000000000e3'),
  'MAJ-1: a new INSERT with timezone_override fills the mirror');
select tests.ok((select timezone_override is null and timezone = 'Asia/Kolkata' from identity.branches where id = 'a1111111-0000-4000-8000-0000000000e4'),
  'MAJ-1: a new INSERT without a zone inherits; the mirror is filled (NOT NULL kept)');
update identity.branches set timezone = 'Asia/Kolkata' where id = 'a1111111-0000-4000-8000-0000000000e1';
select tests.ok((select timezone_override is null and timezone = 'Asia/Kolkata' from identity.branches where id = 'a1111111-0000-4000-8000-0000000000e1'),
  'MAJ-1: a legacy UPDATE to the tenant zone clears the override');
update identity.branches set timezone = 'Europe/London' where id = 'a1111111-0000-4000-8000-0000000000e1';
select tests.ok((select timezone_override = 'Europe/London' and timezone = 'Europe/London' from identity.branches where id = 'a1111111-0000-4000-8000-0000000000e1'),
  'MAJ-1: a legacy UPDATE to another zone sets the override');
update identity.branches set name = 'Renamed (synthetic)' where id = 'a1111111-0000-4000-8000-0000000000e1';
select tests.ok((select timezone_override = 'Europe/London' from identity.branches where id = 'a1111111-0000-4000-8000-0000000000e1'),
  'MAJ-1: other updates keep the override');

-- tenant zone change cascades to the mirror of inheriting branches only (Beta has 1 future booking)
select * from identity.change_time_zone_v1('22222222-2222-4222-8222-222222222222', null, 'Europe/Paris', true);
select tests.ok((select timezone = 'Europe/Paris' and timezone_override is null from identity.branches where id = 'b2222222-0000-4000-8000-000000000001'),
  'MAJ-1: a confirmed tenant zone change moves the mirror of inheriting branches');
select * from identity.change_time_zone_v1('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-0000000000e4', 'Asia/Tokyo', true);
select * from identity.change_time_zone_v1('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-0000000000e3', null, true);
select tests.ok(
  (select timezone = 'Asia/Tokyo' and timezone_override = 'Asia/Tokyo' from identity.branches where id = 'a1111111-0000-4000-8000-0000000000e4')
  and (select timezone = 'Asia/Kolkata' and timezone_override is null from identity.branches where id = 'a1111111-0000-4000-8000-0000000000e3'),
  'MAJ-1: change_time_zone_v1 on a branch keeps the mirror equal to the effective zone');
select tests.ok(
  (select bool_and(b.timezone = identity.branch_time_zone_v1(b.id)) from identity.branches b),
  'MAJ-1: after all of the above the mirror still equals the effective zone everywhere');

-- ========================================= MAJ-2: a deleted branch revokes scoped roles ==
insert into auth.users (id, email, role, aud) values
  ('0a000000-0000-4000-8000-0000000000e5', 'doctor-east@alpha.example', 'authenticated', 'authenticated');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-0000000000e5', 'a1111111-0000-4000-8000-000000000002', 'doctor', 'active');
select tests.authenticate_as('doctor-east@alpha.example');
select tests.ok(identity.has_tenant_role('11111111-1111-4111-8111-111111111111', array['doctor']),
  'MAJ-2 setup: the East-only doctor has the doctor role in Alpha');
select tests.ok((select count(*) > 0 from patient.patients), 'MAJ-2 setup: and reads Alpha patients');
select tests.authenticate_as('consultant@shared.example');
select tests.ok((select count(*) > 0 from patient.patients where tenant_id = '11111111-1111-4111-8111-111111111111'),
  'MAJ-2 setup: the consultant (doctor@Alpha East + doctor@Beta) reads Alpha patients');

select tests.authenticate_as('admin@alpha.example');
select identity.soft_delete_branch('a1111111-0000-4000-8000-000000000002');

select tests.authenticate_as('doctor-east@alpha.example');
select tests.ok(not identity.has_tenant_role('11111111-1111-4111-8111-111111111111', array['doctor']),
  'MAJ-2: after East is deleted has_tenant_role(Alpha, doctor) is false');
select tests.ok(not exists (select identity.current_tenant_ids()), 'MAJ-2: current_tenant_ids() is empty');
select tests.ok((select count(*) = 0 from patient.patients), 'MAJ-2: 0 patients visible');
select tests.ok((select count(*) = 0 from identity.my_memberships()), 'MAJ-2: my_memberships() is empty');
select tests.throws_ok($$select identity.set_active_context('11111111-1111-4111-8111-111111111111')$$,
  '42501', 'MAJ-2: cannot switch into the tenant any more');
select tests.as_superuser();
select tests.ok((select count(*) = 0 from identity.resolve_active_context('0a000000-0000-4000-8000-0000000000e5')),
  'MAJ-2: resolve_active_context finds no tenant (the API grant then has no roles)');
select tests.ok(
  (select tenant_id = '22222222-2222-4222-8222-222222222222' from identity.resolve_active_context('0d000000-0000-4000-8000-000000000001')),
  'MAJ-2: the consultant resolves to Beta only');
select tests.authenticate_as('consultant@shared.example');
select tests.ok((select count(*) = 0 from patient.patients where tenant_id = '11111111-1111-4111-8111-111111111111'),
  'MAJ-2: the consultant no longer reads Alpha patients');
select tests.ok(not identity.shares_tenant_with('0a000000-0000-4000-8000-000000000001'),
  'MAJ-2: shares_tenant_with no longer links the consultant to Alpha staff');
select tests.ok((select count(*) > 0 from patient.patients where tenant_id = '22222222-2222-4222-8222-222222222222'),
  'MAJ-2: the consultant keeps the tenant-wide Beta role');

select tests.authenticate_as('admin@alpha.example');
select identity.restore_branch('a1111111-0000-4000-8000-000000000002');
select tests.authenticate_as('doctor-east@alpha.example');
select tests.ok(identity.has_tenant_role('11111111-1111-4111-8111-111111111111', array['doctor']),
  'MAJ-2: restoring the branch restores the scoped role');

-- ============================================================ MIN-1: DST-safe slots ==
select tests.as_superuser();
update identity.branches set timezone_override = 'America/New_York' where id = 'a1111111-0000-4000-8000-000000000002';
insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id)
values ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000002');
insert into appointment.schedules (tenant_id, branch_id, practitioner_id, weekday, start_time, end_time, slot_minutes, valid_from)
values ('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000002',
        7, '00:00', '04:00', 30, '2026-10-01');
select tests.authenticate_as('admin@alpha.example');
create temporary table t_fall on commit drop as
  select * from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
                                            '2026-11-01', '2026-11-01', 'c1111111-0000-4000-8000-000000000002');
select tests.ok((select bool_and(slot_end - slot_start = interval '30 minutes') from t_fall),
  'MIN-1 fall back (2026-11-01 New York): every slot lasts exactly 30 minutes (was: a 90-minute 00:30 slot)');
select tests.ok(
  (select count(*) = count(distinct (slot_start at time zone 'America/New_York')::time) and count(*) = 8 from t_fall),
  'MIN-1 fall back: each of the 8 wall-clock slots 00:00-03:30 is offered once');
select tests.ok(
  not exists (select 1 from t_fall a join t_fall b on a.slot_start < b.slot_start and a.slot_end > b.slot_start),
  'MIN-1 fall back: no two slots overlap');
create temporary table t_spring on commit drop as
  select * from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
                                            '2027-03-14', '2027-03-14', 'c1111111-0000-4000-8000-000000000002');
select tests.ok((select count(*) = 6 and bool_and(slot_end - slot_start = interval '30 minutes') from t_spring),
  'MIN-1 spring forward (2027-03-14 New York): no error; the nonexistent 02:00 and 02:30 are skipped (6 slots of 30 min)');
select tests.ok(
  not exists (select 1 from t_spring where (slot_start at time zone 'America/New_York')::time in ('02:00', '02:30')),
  'MIN-1 spring forward: no slot starts at a nonexistent local time');
select tests.ok(
  (select count(*) > 0 from appointment.available_slots('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002',
                                                        '2027-03-08', '2027-03-20', 'c1111111-0000-4000-8000-000000000002')),
  'MIN-1: a range that contains the DST day no longer fails as a whole');

-- ================================================== MIN-2: POSIX suffixes and aliases ==
select tests.ok(not identity.is_valid_time_zone('Asia/Kolkata+5') and not identity.is_valid_time_zone('Asia/Kolkata-05:30')
                and not identity.is_valid_time_zone('America/New_York5') and not identity.is_valid_time_zone('UTC+5'),
  'MIN-2: POSIX-suffixed names (Asia/Kolkata+5 = UTC-5) are rejected');
select tests.ok(identity.is_valid_time_zone('America/Port-au-Prince') and identity.is_valid_time_zone('America/North_Dakota/New_Salem')
                and identity.is_valid_time_zone('Asia/Calcutta'),
  'MIN-2: hyphenated, three-part and alias names are still accepted');
select tests.throws_ok($$select * from identity.change_time_zone_v1('11111111-1111-4111-8111-111111111111', null, 'Asia/Kolkata+5', true)$$,
  '22023', 'MIN-2: a POSIX-suffixed zone cannot be stored');
select tests.ok(
  (select changed and time_zone = 'Asia/Kolkata'
   from identity.change_time_zone_v1('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'Asia/Calcutta', true)),
  'MIN-2: Asia/Calcutta is canonicalised to Asia/Kolkata');

rollback;
