-- Tenant time zone (migration 20261012090100): required + validated, branch override, every
-- day-based rule uses the branch-local day, the 00:00-05:30 IST edge, zone-change lock, create_tenant.
begin;

-- ========================================================================= schema ==
select tests.ok(
  (select is_nullable = 'NO' and column_default is null from information_schema.columns
   where table_schema = 'identity' and table_name = 'tenants' and column_name = 'time_zone'),
  'tenants.time_zone is required (NOT NULL, no default)');
select tests.ok(
  (select is_nullable = 'YES' and column_default is null from information_schema.columns
   where table_schema = 'identity' and table_name = 'branches' and column_name = 'timezone_override'),
  'branches.timezone_override is an optional override (nullable, no default)');
select tests.ok(
  (select is_nullable = 'NO' from information_schema.columns
   where table_schema = 'identity' and table_name = 'branches' and column_name = 'timezone'),
  'MAJ-1: branches.timezone keeps its old shape (NOT NULL) for readers built before this migration');
select tests.ok(
  (select column_default is null from information_schema.columns
   where table_schema = 'appointment' and table_name = 'schedules' and column_name = 'valid_from'),
  'schedules.valid_from no longer defaults to current_date (the UTC date)');
select tests.ok(
  identity.is_valid_time_zone('Asia/Kolkata') and identity.is_valid_time_zone('America/New_York')
  and not identity.is_valid_time_zone('Mars/Olympus_Mons') and not identity.is_valid_time_zone('')
  and not identity.is_valid_time_zone(null),
  'is_valid_time_zone() accepts IANA names and rejects unknown/empty/null');

select tests.as_superuser();
select tests.throws_ok($$insert into identity.tenants (code, name) values ('tz-missing', 'No zone (synthetic)')$$,
  '23502', 'a tenant without a time zone is rejected');
select tests.throws_ok($$insert into identity.tenants (code, name, time_zone) values ('tz-bad', 'Bad zone (synthetic)', 'Mars/Olympus_Mons')$$,
  '22023', 'an unknown time zone is rejected');
select tests.throws_ok($$update identity.branches set timezone = 'Not/AZone' where id = 'a1111111-0000-4000-8000-000000000002'$$,
  '22023', 'an unknown zone written by a legacy writer is rejected');
select tests.throws_ok($$update identity.branches set timezone_override = 'Not/AZone' where id = 'a1111111-0000-4000-8000-000000000002'$$,
  '22023', 'an unknown branch override is rejected');
select tests.ok(
  (select bool_and(timezone_override is null and timezone = 'Asia/Kolkata') from identity.branches)
  and (select bool_and(time_zone = 'Asia/Kolkata') from identity.tenants),
  'seed: tenants are Asia/Kolkata and branches inherit it (no override; the mirror shows the effective zone)');

-- ============================================================== zone resolution ==
select tests.ok(identity.branch_time_zone_v1('a1111111-0000-4000-8000-000000000001') = 'Asia/Kolkata', 'a branch inherits the tenant zone');
update identity.branches set timezone_override = 'UTC' where id = 'a1111111-0000-4000-8000-000000000002';
select tests.ok(identity.branch_time_zone_v1('a1111111-0000-4000-8000-000000000002') = 'UTC', 'a branch override wins');

-- the midnight-05:30 IST edge: 2026-10-09 19:00Z is 00:30 on Oct 10 in India, still Oct 9 in UTC
select tests.ok(identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001', '2026-10-09 19:00:00+00') = '2026-10-10',
  'IST branch at 19:00Z (00:30 IST) is already the NEXT day');
select tests.ok(identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001', '2026-10-09 18:29:59+00') = '2026-10-09',
  'IST branch at 18:29:59Z (23:59:59 IST) is still the same day');
select tests.ok(identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000001', '2026-10-10 00:00:00+05:30') = '2026-10-10'
  and ('2026-10-10 00:00:00+05:30'::timestamptz at time zone 'UTC')::date = '2026-10-09',
  'IST midnight belongs to the new IST day although the UTC date is the previous one');
select tests.ok(identity.branch_local_date_v1('a1111111-0000-4000-8000-000000000002', '2026-10-09 19:00:00+00') = '2026-10-09',
  'the UTC-override branch keeps the UTC day at the same instant');

-- ================================================================ day-based rules ==
-- schedule default valid_from = branch-local today
select tests.authenticate_as('admin@alpha.example');
insert into appointment.schedules (id, tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes)
values ('d1111111-0000-4000-8000-0000000000a1', '11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000002',
        'a1111111-0000-4000-8000-000000000001', 7, '08:00', '09:00', 30);
select tests.as_superuser();
select tests.ok(
  (select valid_from = identity.branch_local_date_v1(branch_id) from appointment.schedules where id = 'd1111111-0000-4000-8000-0000000000a1'),
  'a schedule without valid_from starts on the branch-local today');

-- slot generation uses the branch zone (override vs inherited)
select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  (select min(slot_start) from appointment.available_slots('11111111-1111-4111-8111-111111111111',
     'a1111111-0000-4000-8000-000000000002', (date '2030-01-07' + tests.fwd_days()), (date '2030-01-07' + tests.fwd_days()))) = (timestamptz '2030-01-07 09:00:00+00' + tests.fwd()),
  'slots at the UTC-override branch: 09:00 local = 09:00Z');
select tests.ok(
  (select min(slot_start) from appointment.available_slots('11111111-1111-4111-8111-111111111111',
     'a1111111-0000-4000-8000-000000000001', (date '2030-01-07' + tests.fwd_days()), (date '2030-01-07' + tests.fwd_days()))) = (timestamptz '2030-01-07 10:20:00+05:30' + tests.fwd()),
  'slots at an inheriting branch are IST wall-clock (10:00 IST is booked in the seed, so 10:20 IST is first)');

-- queue day + token reset follow the branch-local day
select tests.as_superuser();
update identity.branches set timezone_override = 'Pacific/Kiritimati', is_active = true where id = 'a1111111-0000-4000-8000-000000000002';
select tests.authenticate_as('admin@alpha.example');
create temporary table t_tok on commit drop as
  select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000003');
select tests.ok(
  (select queue_date = (now() at time zone 'Pacific/Kiritimati')::date and token_no = 1 from t_tok),
  'queue day (and token #1) is the branch-local day of the override zone (UTC+14)');
create temporary table t_tok2 on commit drop as
  select * from appointment.check_in_walk_in('a1111111-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000002');
select tests.ok(
  (select queue_date = (now() at time zone 'Asia/Kolkata')::date and token_no = 1 from t_tok2),
  'an inheriting branch issues tokens on the tenant-zone day');

-- =============================================================== zone-change lock ==
-- clients change zones only through identity.change_time_zone_v1 (re-review R5)
select tests.throws_ok($$update identity.tenants set time_zone = 'Europe/London' where id = '11111111-1111-4111-8111-111111111111'$$,
  '42501', 'R5: a client cannot UPDATE tenants.time_zone directly (no column grant)');
select tests.throws_ok($$update identity.branches set timezone_override = 'Asia/Dubai' where id = 'a1111111-0000-4000-8000-000000000001'$$,
  '42501', 'R5: a client cannot UPDATE branches.timezone_override directly (no column grant)');
select tests.throws_ok($$update identity.branches set timezone = 'Asia/Dubai' where id = 'a1111111-0000-4000-8000-000000000001'$$,
  '55000', 'MAJ-1/R5: a legacy client write of branches.timezone gets the same locks (today''s queue here)');
select tests.throws_ok($$select * from identity.change_time_zone_v1('11111111-1111-4111-8111-111111111111', null, 'Europe/London', true)$$,
  '55000', 'tenant zone change is blocked while an inheriting branch has queue entries today (even confirmed)');
select tests.throws_ok($$select * from identity.change_time_zone_v1('11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'Asia/Dubai', true)$$,
  '55000', 'a branch override change is blocked while that branch has queue entries today (even confirmed)');
select tests.authenticate_as('admin@beta.example');
create temporary table t_cz on commit drop as
  select * from identity.change_time_zone_v1('22222222-2222-4222-8222-222222222222', null, 'Asia/Dubai');
grant select on t_cz to public;
select tests.ok((select not changed and future_bookings = 1 and time_zone = 'Asia/Kolkata' from t_cz)
                and (select time_zone = 'Asia/Kolkata' from identity.tenants where id = '22222222-2222-4222-8222-222222222222'),
  'R5: with a future booking and no confirmation nothing changes; the count (1) is returned');
select tests.ok(
  (select changed and future_bookings = 1 and time_zone = 'Asia/Dubai'
   from identity.change_time_zone_v1('22222222-2222-4222-8222-222222222222', null, 'Asia/Dubai', true)),
  'R5: confirmed, the tenant_admin changes their tenant zone');
select tests.ok(identity.is_valid_time_zone((select time_zone from identity.tenants where id = '22222222-2222-4222-8222-222222222222')),
  'the stored zone is valid');
select tests.ok(
  (select changed and future_bookings = 0
   from identity.change_time_zone_v1('22222222-2222-4222-8222-222222222222', null, 'Asia/Dubai')),
  'R5: no effective change -> no confirmation needed (count 0)');
select tests.throws_ok($$select * from identity.change_time_zone_v1('22222222-2222-4222-8222-222222222222', null, 'Nowhere/Land', true)$$,
  '22023', 'tenant_admin cannot store an invalid zone');
select tests.throws_ok($$select * from identity.change_time_zone_v1('22222222-2222-4222-8222-222222222222', null, null, true)$$,
  '22023', 'the tenant zone cannot be cleared');
select tests.throws_ok($$select * from identity.change_time_zone_v1('22222222-2222-4222-8222-222222222222', 'a1111111-0000-4000-8000-000000000001', 'UTC', true)$$,
  'P0002', 'another tenant''s branch -> P0002');
select tests.authenticate_as('doctor@beta.example');
select tests.throws_ok($$select * from identity.change_time_zone_v1('22222222-2222-4222-8222-222222222222', null, 'UTC', true)$$,
  '42501', 'non-admins cannot change the tenant zone (403)');
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$select * from identity.change_time_zone_v1('22222222-2222-4222-8222-222222222222', null, 'UTC', true)$$,
  'P0002', 'another tenant''s admin cannot change it (404)');

-- ================================================================= create_tenant ==
-- No platform operator is seeded (code review MIN-5): create one for this transaction only.
select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e000000-0000-4000-8000-000000000001', 'platform@medicore.example', 'authenticated', 'authenticated');
insert into identity.platform_admins (user_id) values ('0e000000-0000-4000-8000-000000000001');
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$select identity.create_tenant('tz-new', 'New (synthetic)', 'Asia/Kolkata')$$,
  '42501', 'a tenant admin is not a platform admin: create_tenant -> 42501');
select tests.authenticate_as('platform@medicore.example');
select tests.throws_ok($$select identity.create_tenant('tz-new', 'New (synthetic)', 'Mars/Olympus_Mons')$$,
  '22023', 'create_tenant validates the zone');
select tests.throws_ok($$select identity.create_tenant('tz-new', 'New (synthetic)', null)$$,
  '22023', 'create_tenant requires a zone');
select tests.throws_ok($$select identity.create_tenant('demo-alpha', 'Dup (synthetic)', 'Asia/Kolkata')$$,
  '23505', 'duplicate tenant code -> 23505');
create temporary table t_new on commit drop as
  select identity.create_tenant('tz-new', 'New Hospital (synthetic)', 'America/New_York', 'outsider@example.test') as id;
grant select on t_new to public;
select tests.as_superuser();
select tests.ok(
  (select time_zone = 'America/New_York' and created_by = '0e000000-0000-4000-8000-000000000001'
   from identity.tenants where id = (select id from t_new)),
  'create_tenant stores the zone; created_by is the platform admin');
select tests.ok(
  (select count(*) = 1 and bool_and(code = 'main' and timezone_override is null and timezone = 'America/New_York')
   from identity.branches where tenant_id = (select id from t_new)),
  'create_tenant adds a default branch that inherits the tenant zone');
select tests.ok(
  (select role = 'tenant_admin' and status = 'invited' and branch_id is null
   from identity.memberships where tenant_id = (select id from t_new)),
  'the first admin is invited (consent) as tenant-wide tenant_admin');
select tests.ok(
  identity.branch_time_zone_v1((select id from identity.branches where tenant_id = (select id from t_new))) = 'America/New_York',
  'the default branch resolves to the new tenant zone');
select tests.authenticate_as('outsider@example.test');
select tests.ok(not exists (select 1 from identity.tenants where id = (select id from t_new)),
  'the invitee sees nothing before accepting');
select tests.as_superuser();
set local role service_role;
select tests.ok(identity.create_tenant('tz-svc', 'Service-created (synthetic)', 'Asia/Calcutta') is not null,
  'MIN-5: the identity service (service_role, trusted) may call create_tenant');
reset role;
select tests.ok((select time_zone = 'Asia/Kolkata' from identity.tenants where code = 'tz-svc'),
  'create_tenant stores the zone canonically');
select tests.ok(not exists (select 1 from identity.platform_admins
                            where user_id not in ('0e000000-0000-4000-8000-000000000001', '0e900000-0000-4000-8000-000000000001')),
  'MIN-5: seed.sql seeds no platform operator (only the local/CI synthetic operator from local-platform-operator-seed.sql)');

-- ======================================================== review S6: zone validation ==
select tests.as_superuser();
select tests.ok(identity.is_valid_time_zone('Asia/Calcutta'), 'legacy alias Asia/Calcutta (still sent by some browsers) is accepted');
select * from identity.change_time_zone_v1('22222222-2222-4222-8222-222222222222', null, 'Asia/Calcutta', true);
select tests.ok((select time_zone = 'Asia/Kolkata' from identity.tenants where id = '22222222-2222-4222-8222-222222222222'),
  'an alias is stored canonically (Asia/Calcutta -> Asia/Kolkata)');
select tests.ok(identity.is_valid_time_zone('UTC') and identity.is_valid_time_zone('Etc/UTC')
                and identity.is_valid_time_zone('America/Argentina/Buenos_Aires'),
  'UTC, Etc/UTC and three-part names are accepted');
select tests.ok(not identity.is_valid_time_zone('Etc/GMT+5') and not identity.is_valid_time_zone('Etc/GMT-14')
                and not identity.is_valid_time_zone('Etc/GMT') and not identity.is_valid_time_zone('Etc/Universal'),
  'N3: Etc/GMT+N (inverted POSIX sign: Etc/GMT+5 = UTC-5) and other Etc/* except Etc/UTC are rejected');
select tests.ok(not identity.is_valid_time_zone('localtime'), 'localtime (= the server zone) is rejected');
select tests.ok(not identity.is_valid_time_zone('posixrules'), 'posixrules is rejected');
select tests.ok(not identity.is_valid_time_zone('Factory'), 'Factory is rejected');
select tests.ok(not identity.is_valid_time_zone('posix/Asia/Kolkata') and not identity.is_valid_time_zone('right/UTC'),
  'posix/* and right/* are rejected');
select tests.ok(not identity.is_valid_time_zone('IST') and not identity.is_valid_time_zone('EST'),
  'abbreviations (IST, EST) are rejected');
select tests.ok(not identity.is_valid_time_zone('Asia/Nowhere'), 'a well-formed but unknown name is rejected by the probe');
select tests.ok((select provolatile = 's' and prolang = (select oid from pg_language where lanname = 'plpgsql')
                 and prosrc not ilike '%pg_timezone_names%' from pg_proc where oid = 'identity.is_valid_time_zone(text)'::regprocedure),
  'validation is a cheap probe, not a pg_timezone_names scan');
select tests.throws_ok($$update identity.tenants set time_zone = 'localtime' where id = '22222222-2222-4222-8222-222222222222'$$,
  '22023', 'a tenant cannot be set to localtime');

-- ======================================================== review B2/S7: published v1 ==
create temporary table t_v1 (fn regprocedure) on commit drop;
insert into t_v1 values
  ('identity.branch_time_zone_v1(uuid)'), ('identity.branch_local_date_v1(uuid,timestamptz)'),
  ('identity.branch_exists_v1(uuid,uuid)'), ('identity.branch_tenant_id_v1(uuid)'),
  ('appointment.branch_has_open_activity_v1(uuid,uuid)'), ('appointment.queue_has_entries_v1(uuid,uuid[],date[])'),
  ('appointment.patient_has_active_visits_v1(uuid,uuid)'), ('patient.patient_exists_v1(uuid,uuid)');
select tests.ok(
  (select bool_and(p.prosecdef and p.proconfig @> array['search_path=""']
                   and has_function_privilege('service_role', p.oid, 'execute')
                   and not has_function_privilege('anon', p.oid, 'execute')
                   -- re-review R6: the two zone resolvers are granted to authenticated.
                   -- branch_exists_v1 is too, so the legacy host can call it until that host is stopped
                   -- (docs/runbooks/monolith-cutover.md). The service roles are granted it as well.
                   and has_function_privilege('authenticated', p.oid, 'execute')
                       = (p.proname in ('branch_time_zone_v1', 'branch_local_date_v1', 'branch_exists_v1')))
   from t_v1 join pg_proc p on p.oid = t_v1.fn),
  'SIGNATURES: the 8 published v1 functions exist, SECURITY DEFINER, search_path pinned, service_role; authenticated for the 2 zone resolvers and branch_exists_v1');
select tests.ok(
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'identity' and p.prosrc ~ 'appointment\.(appointments|queue_entries|queue_counters|schedules|practitioners)\M'),
  'B2: no identity function reads appointment tables directly');
select tests.ok(
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'patient' and p.prosrc ~ 'appointment\.(appointments|queue_entries)\M'),
  'B2: no patient function reads appointment tables directly');
select tests.ok(
  not exists (select 1 from pg_proc p where p.oid in (
      'appointment.issue_queue_token(uuid,uuid,uuid,uuid,uuid)'::regprocedure,
      'appointment.check_in(uuid,uuid,uuid,uuid,uuid)'::regprocedure,
      'appointment.check_in_walk_in(uuid,uuid,uuid)'::regprocedure,
      'appointment.available_slots(uuid,uuid,date,date,uuid)'::regprocedure,
      'appointment.assert_tenant_refs(uuid,uuid)'::regprocedure)
    and p.prosrc ~ '(identity\.branches|patient\.patients)\M'),
  'B2: the rewritten scheduling functions use identity/patient v1 functions, not their tables');
select tests.ok(to_regprocedure('identity.branch_time_zone(uuid)') is null and to_regprocedure('identity.branch_local_date(uuid,timestamptz)') is null,
  'only the published v1 zone resolver exists (no unpublished duplicate)');

select tests.authenticate_as('reception@alpha.example');
select tests.ok(identity.branch_time_zone_v1('a1111111-0000-4000-8000-000000000001') = 'Asia/Kolkata',
  'a member resolves its branch zone through branch_time_zone_v1');
select tests.throws_ok($$select identity.branch_time_zone_v1('b2222222-0000-4000-8000-000000000001')$$,
  'P0002', 'another tenant''s branch zone -> P0002 (404-not-403)');
select tests.throws_ok($$select identity.branch_time_zone_v1('00000000-0000-4000-8000-0000000000aa')$$,
  'P0002', 'unknown branch -> P0002 instead of a NULL zone (review N1)');
select tests.throws_ok($$select appointment.queue_has_entries_v1('22222222-2222-4222-8222-222222222222', array['b2222222-0000-4000-8000-000000000001'::uuid], array[current_date])$$,
  '42501', 'R6: a client cannot call queue_has_entries_v1 at all');
select tests.throws_ok($$select patient.patient_exists_v1('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000001')$$,
  '42501', 'R6: a client cannot call patient_exists_v1 at all (no same-tenant existence oracle)');
-- the tenant check itself, as reached through a SECURITY DEFINER caller (owner role + the user's claims)
select tests.as_superuser();
select set_config('request.jwt.claims', json_build_object('sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
select tests.throws_ok($$select appointment.queue_has_entries_v1('22222222-2222-4222-8222-222222222222', array['b2222222-0000-4000-8000-000000000001'::uuid], array[current_date])$$,
  'P0002', 'via a definer path a user cannot probe another tenant''s queue');
select tests.throws_ok($$select patient.patient_exists_v1('22222222-2222-4222-8222-222222222222', 'bb000000-0000-4000-8000-000000000001')$$,
  'P0002', 'via a definer path a user cannot probe another tenant''s patients');
select tests.ok(identity.branch_tenant_id_v1('b2222222-0000-4000-8000-000000000001') is null,
  'branch_tenant_id_v1 hides a foreign branch (NULL)');
select tests.as_superuser();

rollback;
