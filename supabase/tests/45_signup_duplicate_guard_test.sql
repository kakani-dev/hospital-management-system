-- Sign-up duplicate guard (migration 20261025270000). One assertion per case:
-- registered-email block, possible-duplicate flag, resubmit after rejection, and the
-- edges around races, retries, invalid input, case/whitespace, roles, deleted and
-- suspended rows, time zones, dates, partial rollback, and a stale stored flag.
begin;

select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e270000-0000-4000-8000-000000000001', 'op-dup@medicore.example', 'authenticated', 'authenticated'),
  ('0e270000-0000-4000-8000-000000000002', 'admin@dup-guard.example', 'authenticated', 'authenticated'),
  ('0e270000-0000-4000-8000-000000000003', 'doctor@dup-guard.example', 'authenticated', 'authenticated'),
  ('0e270000-0000-4000-8000-000000000004', 'invited@dup-guard.example', 'authenticated', 'authenticated'),
  ('0e270000-0000-4000-8000-000000000005', 'paused-admin@dup-guard.example', 'authenticated', 'authenticated'),
  ('0e270000-0000-4000-8000-000000000006', 'auth-other@dup-guard.example', 'authenticated', 'authenticated'),
  ('0e270000-0000-4000-8000-000000000007', 'deleted-admin@dup-guard.example', 'authenticated', 'authenticated'),
  ('0e270000-0000-4000-8000-000000000008', 'keeper@dup-guard.example', 'authenticated', 'authenticated'),
  ('0e270000-0000-4000-8000-000000000009', 'member-susp@dup-guard.example', 'authenticated', 'authenticated'),
  ('0e270000-0000-4000-8000-00000000000a', 'member-arch@dup-guard.example', 'authenticated', 'authenticated');
insert into identity.user_profiles (id, email) values
  ('0e270000-0000-4000-8000-000000000006', 'profile-admin@dup-guard.example');
select identity.grant_platform_admin('op-dup@medicore.example');

-- Readers below stay anon or a hospital user. These helpers are security definer so the
-- assertions can see the rows the real grants hide. They exist only in this transaction.
create or replace function tests.signup_id(p_email text)
returns uuid language sql security definer set search_path = '' as $$
  select r.id from identity.tenant_signup_requests r
   where r.contact_email = lower(pg_catalog.btrim(p_email)) and not r.is_deleted
   order by r.created_on desc limit 1
$$;
create or replace function tests.signup_row(p_email text)
returns identity.tenant_signup_requests language sql security definer set search_path = '' as $$
  select r.* from identity.tenant_signup_requests r
   where r.contact_email = lower(pg_catalog.btrim(p_email)) and not r.is_deleted
   order by r.created_on desc limit 1
$$;
create or replace function tests.signup_count(p_email text, p_status text default null)
returns bigint language sql security definer set search_path = '' as $$
  select count(*) from identity.tenant_signup_requests r
   where r.contact_email = lower(pg_catalog.btrim(p_email)) and not r.is_deleted
     and (p_status is null or r.status = p_status)
$$;
create or replace function tests.mail_count(p_recipient text, p_template text default null)
returns bigint language sql security definer set search_path = '' as $$
  select count(*) from identity.pending_emails p
   where p.recipient = lower(pg_catalog.btrim(p_recipient))
     and (p_template is null or p.template_key = p_template)
$$;
create or replace function tests.tenant_id(p_code text)
returns uuid language sql security definer set search_path = '' as $$
  select t.id from identity.tenants t where t.code = p_code
$$;

select identity.create_tenant('dup-live', 'Dup Live Hospital', 'Asia/Kolkata', null);
select identity.create_tenant('dup-susp', 'Dup Suspended Hospital', 'Asia/Kolkata', null);
select identity.create_tenant('dup-arch', 'Dup Archived Hospital', 'UTC', null);
select identity.create_tenant('dup-soft', 'Dup Soft Hospital', 'UTC', null);

insert into identity.memberships (tenant_id, user_id, role, status)
select t.id, '0e270000-0000-4000-8000-000000000002', 'tenant_admin', 'active' from identity.tenants t where t.code = 'dup-live';
insert into identity.memberships (tenant_id, user_id, role, status)
select t.id, '0e270000-0000-4000-8000-000000000003', 'doctor', 'active' from identity.tenants t where t.code = 'dup-live';
insert into identity.memberships (tenant_id, user_id, role, status)
select t.id, '0e270000-0000-4000-8000-000000000004', 'tenant_admin', 'invited' from identity.tenants t where t.code = 'dup-live';
insert into identity.memberships (tenant_id, user_id, role, status)
select t.id, '0e270000-0000-4000-8000-000000000005', 'tenant_admin', 'suspended' from identity.tenants t where t.code = 'dup-live';
insert into identity.memberships (tenant_id, user_id, role, status)
select t.id, '0e270000-0000-4000-8000-000000000006', 'tenant_admin', 'active' from identity.tenants t where t.code = 'dup-live';
insert into identity.memberships (tenant_id, user_id, role, status)
select t.id, '0e270000-0000-4000-8000-000000000008', 'tenant_admin', 'active' from identity.tenants t where t.code = 'dup-soft';
insert into identity.memberships (tenant_id, user_id, role, status)
select t.id, '0e270000-0000-4000-8000-000000000007', 'tenant_admin', 'active' from identity.tenants t where t.code = 'dup-soft';
select tests.as_owner('identity.memberships'::regclass);
update identity.memberships set is_deleted = true
 where user_id = '0e270000-0000-4000-8000-000000000007';
select tests.as_superuser();
insert into identity.memberships (tenant_id, user_id, role, status)
select t.id, '0e270000-0000-4000-8000-000000000009', 'tenant_admin', 'active' from identity.tenants t where t.code = 'dup-susp';
insert into identity.memberships (tenant_id, user_id, role, status)
select t.id, '0e270000-0000-4000-8000-00000000000a', 'tenant_admin', 'active' from identity.tenants t where t.code = 'dup-arch';
update identity.tenants set status = 'suspended' where code = 'dup-susp';
update identity.tenants set status = 'archived' where code = 'dup-arch';

-- ============================================================ privileges ==
select tests.ok(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'identity' and has_function_privilege('anon', p.oid, 'execute'))
  = array['preview_invite_link', 'submit_tenant_signup'],
  'anon can still execute only submit_tenant_signup and preview_invite_link');
select tests.ok(
  not has_function_privilege('anon', 'identity.signup_email_registered(text)', 'execute')
  and not has_function_privilege('anon', 'identity.signup_duplicate_hits(uuid, text, text)', 'execute')
  and not has_function_privilege('authenticated', 'identity.signup_duplicate_hits(uuid, text, text)', 'execute')
  and not has_table_privilege('anon', 'identity.tenant_signup_requests', 'select'),
  'match helpers and match ids are not readable by anon or a hospital user');
select tests.ok(
  (select pg_get_function_identity_arguments(p.oid) not like '%uuid%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'identity' and p.proname = 'submit_tenant_signup'),
  'submit_tenant_signup takes no tenant id; the caller cannot choose a hospital');
select tests.ok(
  (select pg_get_function_result(p.oid) = 'uuid'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'identity' and p.proname = 'submit_tenant_signup'),
  'submit returns only a request id, never matched tenant or request ids');

-- =============================================================== normalize ==
select tests.ok(identity.hospital_name_key('  LOTUS   HOSPITAL ') = 'lotus', 'name: case and spaces stripped, hospital suffix dropped');
select tests.ok(identity.hospital_name_key('Lotus Clinic.') = identity.hospital_name_key('lotus-hospital'), 'name: punctuation and clinic/hospital suffixes collapse');
select tests.ok(identity.hospital_name_key('St. Mary''s Clinic') = identity.hospital_name_key('st marys hospital'), 'name: punctuation inside the word is stripped');
select tests.ok(identity.hospital_name_key('Lotus Hospitals') = 'lotus', 'name: the longer suffix hospitals is removed whole');
select tests.ok(identity.hospital_name_key('Lotus Hospital Clinic') = 'lotus', 'name: stacked suffixes are removed');
select tests.ok(identity.hospital_name_key('City Hospitality') = 'cityhospitality', 'name: hospitality is not treated as the suffix hospital');
select tests.ok(identity.hospital_name_key('Hospital') = '' and identity.hospital_name_key('Clinic') = '', 'name: a suffix-only name has an empty key and matches nothing');
select tests.ok(identity.phone_key('+91 98765 43210') = '9876543210', 'phone: +91 and separators fold to the national number');
select tests.ok(identity.phone_key('098765-43210') = '9876543210' and identity.phone_key('9876543210') = '9876543210', 'phone: leading 0 and plain digits match +91');
select tests.ok(identity.phone_key('919123456789') = '9123456789', 'phone: 91 plus ten digits drops only the country code');
select tests.ok(identity.phone_key('9123456789') = '9123456789' and identity.phone_key('9123456789') <> identity.phone_key('23456789'), 'phone: a ten-digit number that starts with 91 is not a country code');
select tests.ok(identity.phone_key('+1 555 0100') = '15550100', 'phone: a non-91 country code is kept');
select tests.ok(identity.phone_key('') = '' and identity.phone_key(null) = '', 'phone: empty input has an empty key and matches nothing');

-- ========================================================== locks and race ==
create temporary table lock_base on commit drop as
  select count(*)::int as n from pg_locks where locktype = 'advisory';
select identity.signup_lock_key('signup:e:lock-probe@dup-guard.example');
select tests.ok(
  (select count(*) from pg_locks where locktype = 'advisory') > (select n from lock_base),
  'signup_lock_key holds an advisory transaction lock so two sign-ups for one email serialize');
select tests.as_anon();
select tests.throws_ok(
  $$insert into identity.tenant_signup_requests (hospital_name, time_zone, contact_name, contact_email, phone, city)
    values ('Race Hospital', 'UTC', 'Asha', 'race@dup-guard.example', '+91 90000 11111', 'Pune')$$,
  '42501', 'anon cannot insert a second pending row directly');
select tests.as_superuser();
insert into identity.tenant_signup_requests (hospital_name, time_zone, contact_name, contact_email, phone, city)
values ('Race Hospital', 'UTC', 'Asha', 'race@dup-guard.example', '+91 90000 11111', 'Pune');
select tests.throws_ok(
  $$insert into identity.tenant_signup_requests (hospital_name, time_zone, contact_name, contact_email, phone, city)
    values ('Race Clinic', 'UTC', 'Asha', 'RACE@dup-guard.example', '+91 90000 22222', 'Pune')$$,
  '23505', 'the unique index, not only the function check, rejects a second pending email');

-- ====================================================== rule 1: block email ==
select tests.as_anon();
do $body$
declare
  v_msg text := '';
begin
  begin
    perform identity.submit_tenant_signup('Dup Live Clinic', 'Asia/Kolkata', 'Asha', '  ADMIN@dup-guard.example ', '+91 90000 00002', 'Pune', null);
  exception when sqlstate 'P0001' then
    v_msg := sqlerrm;
  end;
  if v_msg <> 'email_already_registered' then
    raise exception 'expected email_already_registered, got %', v_msg;
  end if;
  if position('dup live' in lower(v_msg)) > 0 or position('dup-live' in lower(v_msg)) > 0 then
    raise exception 'registered-email error leaked a hospital: %', v_msg;
  end if;
end
$body$;
select tests.ok(true, 'an active tenant admin email is refused, case- and space-insensitive, with no hospital details');
select tests.ok(
  tests.signup_count('admin@dup-guard.example') = 0
  and tests.mail_count('admin@dup-guard.example') = 0,
  'a refused sign-up writes no request and no acknowledgement email (the statement rolls back)');
do $body$
declare
  v_caught boolean := false;
begin
  begin
    perform identity.submit_tenant_signup('Again Hospital', 'UTC', 'Asha', 'admin@dup-guard.example', '+91 90000 00003', 'Pune', null);
  exception when sqlstate 'P0001' then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'retry should still be refused';
  end if;
end
$body$;
select tests.ok(
  tests.signup_count('admin@dup-guard.example') = 0,
  'retrying a registered email still refuses and still adds no row');
select tests.throws_ok(
  $$select identity.submit_tenant_signup('Profile Hospital', 'UTC', 'Asha', 'profile-admin@dup-guard.example', '+91 90000 00004', 'Pune', null)$$,
  'P0001', 'a profile email that differs from auth.users still counts as the admin');
select tests.ok(
  identity.submit_tenant_signup('Doctor Hospital', 'UTC', 'Doc', 'doctor@dup-guard.example', '+91 90000 00005', 'Pune', null) is not null,
  'a doctor membership does not block a new hospital sign-up');
select tests.ok(
  identity.submit_tenant_signup('Invited Hospital', 'UTC', 'Inv', 'invited@dup-guard.example', '+91 90000 00006', 'Pune', null) is not null,
  'an invited tenant admin has not joined, so the email can still register');
select tests.ok(
  identity.submit_tenant_signup('Paused Hospital', 'UTC', 'Asha', 'paused-admin@dup-guard.example', '+91 90000 00007', 'Pune', null) is not null,
  'a suspended admin membership does not block');
select tests.ok(
  identity.submit_tenant_signup('Deleted Admin Hospital', 'UTC', 'Asha', 'deleted-admin@dup-guard.example', '+91 90000 00008', 'Pune', null) is not null,
  'a soft-deleted admin membership does not block');
select tests.ok(
  identity.submit_tenant_signup('Susp Member Hospital', 'UTC', 'Asha', 'member-susp@dup-guard.example', '+91 90000 00009', 'Pune', null) is not null,
  'an admin of a suspended hospital is not a live membership, so the email can register');
select tests.ok(
  identity.submit_tenant_signup('Arch Member Hospital', 'UTC', 'Asha', 'member-arch@dup-guard.example', '+91 90000 00010', 'Pune', null) is not null,
  'an admin of an archived hospital is not a live membership, so the email can register');

-- Approved request blocks even after the hospital is suspended. A different email on that hospital does not.
select identity.submit_tenant_signup('Approved Susp Hospital', 'Asia/Calcutta', 'Asha', 'approved-susp@dup-guard.example', '+91 90000 00011', 'Pune', null);
select tests.authenticate_as('op-dup@medicore.example');
select identity.platform_approve_signup(
  tests.signup_id('approved-susp@dup-guard.example'), 'dup-appr-susp');
select identity.platform_set_tenant_status(
  tests.tenant_id('dup-appr-susp'), 'suspended', 'Synthetic hold');
select tests.as_anon();
select tests.throws_ok(
  $$select identity.submit_tenant_signup('Approved Susp Again', 'UTC', 'Asha', 'Approved-Susp@dup-guard.example', '+91 90000 00012', 'Pune', null)$$,
  'P0001', 'an approved request still blocks after the hospital is suspended');
select tests.as_owner('identity.tenant_signup_requests'::regclass);
update identity.tenant_signup_requests set is_deleted = true where contact_email = 'doctor@dup-guard.example';
select tests.as_anon();
select tests.ok(
  identity.submit_tenant_signup('Doctor Again', 'UTC', 'Doc', 'doctor@dup-guard.example', '+91 90000 00013', 'Pune', null) is not null,
  'a soft-deleted pending request does not absorb a new one');

-- ===================================================== rule 3: after reject ==
select identity.submit_tenant_signup('Reject Me Hospital', 'UTC', 'Asha', 'reject-me@dup-guard.example', '+91 90000 00014', 'Pune', null);
select tests.authenticate_as('op-dup@medicore.example');
select identity.platform_reject_signup(
  tests.signup_id('reject-me@dup-guard.example'),
  'Not a hospital (synthetic)');
select tests.as_anon();
select tests.ok(
  identity.submit_tenant_signup('Second Chance Clinic', 'Europe/London', 'Asha', 'Reject-Me@dup-guard.example', '+91 90000 00015', 'Pune', null) is not null,
  'a rejected email can sign up again');
select tests.ok(
  tests.signup_count('reject-me@dup-guard.example', 'pending') = 1
  and tests.signup_count('reject-me@dup-guard.example', 'rejected') = 1,
  'resubmit after rejection stores a new pending row and keeps the rejected one');
select tests.throws_ok(
  $$select identity.submit_tenant_signup('Admin Rejected', 'UTC', 'Asha', 'admin@dup-guard.example', '+91 90000 00016', 'Pune', null)$$,
  'P0001', 'a live admin is still blocked when they register again');

-- ===================================================== rule 2: duplicates ==
select tests.ok(
  identity.submit_tenant_signup('  Marble   HOSPITAL ', 'Asia/Kolkata', 'Asha', 'marble-a@dup-guard.example', '+91 98765 43210', 'Pune', 'src-dup-marble') is not null,
  'first marble request is accepted');
select tests.ok(
  (select possible_duplicate = false and duplicate_tenant_ids = '{}' and duplicate_request_ids = '{}'
     from tests.signup_row('marble-a@dup-guard.example')),
  'a request with no match is not flagged');
select tests.ok(
  identity.submit_tenant_signup('marble clinic.', 'Pacific/Kiritimati', 'Bea', 'marble-b@dup-guard.example', '09876543210', 'Pune', null) is not null,
  'a matching name and phone is still accepted');
select tests.ok(
  (select possible_duplicate and name_key = 'marble' and phone_key = '9876543210' and time_zone = 'Pacific/Kiritimati'
     and duplicate_request_ids = array[tests.signup_id('marble-a@dup-guard.example')]
     from tests.signup_row('marble-b@dup-guard.example')),
  'the new request stores the other pending id; zone is kept and does not affect the match');
select tests.ok(
  (select possible_duplicate
     and duplicate_request_ids @> array[tests.signup_id('marble-b@dup-guard.example')]
     from tests.signup_row('marble-a@dup-guard.example')),
  'the earlier pending request is updated to point at the new one');
select tests.authenticate_as('op-dup@medicore.example');
select tests.ok(
  (select possible_duplicate and matched_hospitals = array['marble clinic.']::text[]
     from identity.platform_list_signups('pending') where contact_email = 'marble-a@dup-guard.example'),
  'the operator list shows Possible duplicate and the other hospital name');
select tests.as_anon();
select tests.throws_ok($$select * from identity.platform_list_signups()$$, '42501', 'anonymous callers cannot read duplicate matches');
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$select * from identity.platform_list_signups()$$, '42501', 'a tenant admin cannot read another hospital''s sign-up matches');

-- Phone matches a tenant through the sign-up that created it, even when the name differs.
select tests.as_anon();
select identity.submit_tenant_signup('Phone Origin Hospital', 'UTC', 'Asha', 'phone-origin@dup-guard.example', '+91 90000 33333', 'Pune', null);
select tests.authenticate_as('op-dup@medicore.example');
select identity.platform_approve_signup(
  tests.signup_id('phone-origin@dup-guard.example'), 'dup-phone');
select tests.as_superuser();
update identity.tenants set name = 'Renamed Phone Hospital' where code = 'dup-phone';
select tests.as_anon();
select identity.submit_tenant_signup('Totally Other Name', 'America/New_York', 'Bea', 'phone-next@dup-guard.example', '9000033333', 'Pune', null);
select tests.ok(
  (select possible_duplicate
     and duplicate_tenant_ids = array[tests.tenant_id('dup-phone')]
     from tests.signup_row('phone-next@dup-guard.example')),
  'the same national phone flags the existing tenant');
select tests.authenticate_as('op-dup@medicore.example');
select tests.ok(
  (select matched_hospitals = array['Renamed Phone Hospital']::text[]
     from identity.platform_list_signups('pending') where contact_email = 'phone-next@dup-guard.example'),
  'the matched hospital shown to the operator is the tenant''s current name');

-- Name matches a tenant. A tenant created after filing is visible live even when the stored flag is still false.
select tests.as_anon();
select identity.submit_tenant_signup('Late Match Hospital', 'Asia/Kolkata', 'Asha', 'late-match@dup-guard.example', '+91 90000 44444', 'Pune', null);
select tests.ok(
  (select possible_duplicate = false from tests.signup_row('late-match@dup-guard.example')),
  'stored flag stays false until a match exists');
select tests.as_superuser();
select identity.create_tenant('dup-late', 'Late Match Clinic', 'UTC', null);
select tests.authenticate_as('op-dup@medicore.example');
select tests.ok(
  (select r.possible_duplicate = false from tests.signup_row('late-match@dup-guard.example') r)
  and (select s.possible_duplicate and s.matched_hospitals = array['Late Match Clinic']::text[]
         from identity.platform_list_signups('pending') s where s.contact_email = 'late-match@dup-guard.example'),
  'the operator list recomputes a tenant created after the request; the stored snapshot can be stale');

-- Suspended and archived tenants still count as name matches. Rejected requests do not.
select tests.as_anon();
select identity.submit_tenant_signup('Dup Suspended Clinic', 'UTC', 'Asha', 'susp-name@dup-guard.example', '+91 90000 55555', 'Pune', null);
select identity.submit_tenant_signup('Dup Archived Clinic', 'UTC', 'Asha', 'arch-name@dup-guard.example', '+91 90000 55556', 'Pune', null);
select tests.authenticate_as('op-dup@medicore.example');
select tests.ok(
  (select possible_duplicate from identity.platform_list_signups('pending') where contact_email = 'susp-name@dup-guard.example')
  and (select possible_duplicate from identity.platform_list_signups('pending') where contact_email = 'arch-name@dup-guard.example'),
  'suspended and archived tenants are existing hospitals for the name flag');
select tests.as_anon();
select identity.submit_tenant_signup('Reject Me Hospital', 'UTC', 'Bea', 'reject-name@dup-guard.example', '+91 90000 55557', 'Pune', null);
select tests.ok(
  (select possible_duplicate = false from tests.signup_row('reject-name@dup-guard.example')),
  'a rejected request is not a pending match');

-- Suffix-only and hospitality do not false-match.
select tests.ok(identity.submit_tenant_signup('Hospital', 'UTC', 'Asha', 'suffix-h@dup-guard.example', '+91 90000 66661', 'Pune', null) is not null, 'suffix-only hospital name is accepted');
select tests.ok(identity.submit_tenant_signup('Clinic', 'UTC', 'Asha', 'suffix-c@dup-guard.example', '+91 90000 66662', 'Pune', null) is not null, 'suffix-only clinic name is accepted');
select tests.ok(
  (select possible_duplicate = false from tests.signup_row('suffix-h@dup-guard.example'))
  and (select possible_duplicate = false from tests.signup_row('suffix-c@dup-guard.example')),
  'empty name keys do not flag each other');
select tests.as_superuser();
select identity.create_tenant('dup-city', 'City', 'UTC', null);
select tests.as_anon();
select identity.submit_tenant_signup('City Hospitality', 'UTC', 'Asha', 'hospity@dup-guard.example', '+91 90000 66663', 'Pune', null);
select tests.authenticate_as('op-dup@medicore.example');
select tests.ok(
  (select possible_duplicate = false from identity.platform_list_signups('pending') where contact_email = 'hospity@dup-guard.example'),
  'City Hospitality does not match a tenant named City');
select tests.as_anon();
select identity.submit_tenant_signup('City Hospital', 'UTC', 'Asha', 'city-h@dup-guard.example', '+91 90000 66664', 'Pune', null);
select tests.ok(
  (select duplicate_tenant_ids = array[tests.tenant_id('dup-city')]
     from tests.signup_row('city-h@dup-guard.example')),
  'City Hospital does match a tenant named City');

-- Different hospitals do not flag.
select identity.submit_tenant_signup('Unique Orchid Hospital', 'UTC', 'Asha', 'orchid@dup-guard.example', '+1 555 0198', 'Pune', null);
select tests.ok(
  (select possible_duplicate = false from tests.signup_row('orchid@dup-guard.example')),
  'a distinct name and phone is not a duplicate');

-- 91-prefix trap: these two must not flag each other.
select identity.submit_tenant_signup('Nine Alpha Hospital', 'UTC', 'Asha', 'nine-a@dup-guard.example', '9123456789', 'Pune', null);
select identity.submit_tenant_signup('Nine Beta Clinic', 'UTC', 'Bea', 'nine-b@dup-guard.example', '23456789', 'Pune', null);
select tests.ok(
  (select possible_duplicate = false from tests.signup_row('nine-b@dup-guard.example')),
  'a ten-digit phone starting with 91 does not match the number with those digits removed');

-- St. Mary's punctuation.
select identity.submit_tenant_signup('St. Mary''s Clinic', 'UTC', 'Asha', 'mary-a@dup-guard.example', '+91 90000 77771', 'Pune', null);
select identity.submit_tenant_signup('st marys hospital', 'UTC', 'Bea', 'mary-b@dup-guard.example', '+91 90000 77772', 'Pune', null);
select tests.ok(
  (select possible_duplicate from tests.signup_row('mary-b@dup-guard.example')),
  'punctuation and case variants of the same hospital name are flagged');

-- Pending duplicate email is absorbed (202), including a retry, and does not send a second email.
select identity.submit_tenant_signup('Absorb Hospital', 'UTC', 'Asha', 'absorb@dup-guard.example', '+91 90000 88881', 'Pune', null);
select tests.ok(
  identity.submit_tenant_signup('Absorb Clinic', 'UTC', 'Asha', '  ABSORB@dup-guard.example ', '+91 90000 88882', 'Pune', null) is null,
  'a second pending request for the same email is absorbed');
select tests.ok(
  tests.signup_count('absorb@dup-guard.example') = 1
  and tests.mail_count('absorb@dup-guard.example', 'signup_received') = 1,
  'double-submit keeps one row and one acknowledgement');

-- Soft-deleted approved request no longer blocks.
select identity.submit_tenant_signup('Soft Approved Hospital', 'UTC', 'Asha', 'soft-appr@dup-guard.example', '+91 90000 88883', 'Pune', null);
select tests.authenticate_as('op-dup@medicore.example');
select identity.platform_approve_signup(
  tests.signup_id('soft-appr@dup-guard.example'), 'dup-soft-appr');
select tests.as_owner('identity.tenant_signup_requests'::regclass);
update identity.tenant_signup_requests set is_deleted = true where contact_email = 'soft-appr@dup-guard.example';
select tests.as_anon();
select tests.ok(
  identity.submit_tenant_signup('Soft Approved Again', 'UTC', 'Asha', 'soft-appr@dup-guard.example', '+91 90000 88884', 'Pune', null) is not null,
  'a soft-deleted approved request does not block the email');

-- =============================================================== confirm ==
select tests.authenticate_as('op-dup@medicore.example');
select tests.throws_ok(
  $$select * from identity.platform_approve_signup(
      tests.signup_id('late-match@dup-guard.example'),
      'dup-late-new')$$,
  'P0001', 'approving a live duplicate without confirm is refused');
select tests.as_superuser();
select tests.ok(
  not exists (select 1 from identity.tenants where code = 'dup-late-new')
  and (select status = 'pending' from tests.signup_row('late-match@dup-guard.example'))
  and not exists (select 1 from identity.pending_emails where recipient = 'late-match@dup-guard.example' and template_key = 'signup_approved'),
  'refused approve rolls back: no tenant, request still pending, no approval email');
select tests.authenticate_as('op-dup@medicore.example');
select tests.ok(
  (select count(*) = 1 from identity.platform_approve_signup(
      tests.signup_id('late-match@dup-guard.example'),
      'dup-late-new', true)),
  'confirming the possible duplicate approves and creates the hospital');
select tests.as_superuser();
select tests.ok(
  (select r.status = 'approved' and r.possible_duplicate
     and r.duplicate_tenant_ids = array[tests.tenant_id('dup-late')]
     from tests.signup_row('late-match@dup-guard.example') r),
  'the approved row records the matched tenant id');

-- A stored flag that is no longer a live match does not require confirm.
select tests.as_anon();
select identity.submit_tenant_signup('Gone Match Hospital', 'UTC', 'Asha', 'gone-a@dup-guard.example', '+91 90000 99991', 'Pune', null);
select identity.submit_tenant_signup('Gone Match Clinic', 'UTC', 'Bea', 'gone-b@dup-guard.example', '+91 90000 99992', 'Pune', null);
select tests.authenticate_as('op-dup@medicore.example');
select identity.platform_reject_signup(
  tests.signup_id('gone-a@dup-guard.example'),
  'Synthetic withdrawal');
select tests.ok(
  (select r.possible_duplicate from tests.signup_row('gone-b@dup-guard.example') r)
  and (select s.possible_duplicate = false from identity.platform_list_signups('pending') s where s.contact_email = 'gone-b@dup-guard.example'),
  'after the other request is rejected the live flag clears even if the stored snapshot is stale');
select tests.ok(
  (select count(*) = 1 from identity.platform_approve_signup(
      tests.signup_id('gone-b@dup-guard.example'),
      'dup-gone', false)),
  'approve proceeds without confirm when the live match has gone away');

-- A non-duplicate still approves with the two-argument call (default confirm false).
select tests.as_anon();
select identity.submit_tenant_signup('Plain Hospital', 'Asia/Calcutta', 'Asha', 'plain@dup-guard.example', '+91 90000 12121', 'Pune', null);
select tests.authenticate_as('op-dup@medicore.example');
select identity.platform_approve_signup(tests.signup_id('plain@dup-guard.example'), 'dup-plain');
select tests.as_superuser();
select tests.ok(
  (select time_zone = 'Asia/Kolkata' from identity.tenants where code = 'dup-plain'),
  'a request that is not a duplicate still approves, and Asia/Calcutta is stored as Asia/Kolkata');

-- ===================================================== invalid and dates ==
select tests.as_anon();
select identity.submit_tenant_signup('Edge Zone Hospital', 'UTC', 'Asha', 'edge-zone@dup-guard.example', '+91 90000 13131', 'Pune', null);
select tests.throws_ok(
  $$select identity.submit_tenant_signup('Edge Zone Clinic', 'IST', 'Asha', 'edge-bad-zone@dup-guard.example', '+91 90000 13132', 'Pune', null)$$,
  '22023', 'an unknown time zone is refused');
select tests.ok(
  tests.signup_count('edge-bad-zone@dup-guard.example') = 0
  and (select possible_duplicate = false from tests.signup_row('edge-zone@dup-guard.example')),
  'invalid time zone writes nothing and does not flag the hospital it would have matched');
select tests.throws_ok(
  $$select identity.submit_tenant_signup('   ', 'UTC', 'Asha', 'blank-name@dup-guard.example', '+91 90000 13133', 'Pune', null)$$,
  '23514', 'a blank hospital name is refused');
select tests.throws_ok(
  $$select identity.submit_tenant_signup('Ok Name', 'UTC', 'Asha', '   ', '+91 90000 13134', 'Pune', null)$$,
  '23514', 'a blank email is refused');
select tests.throws_ok(
  $$select identity.submit_tenant_signup('Ok Name', 'UTC', 'Asha', 'not-an-email', '+91 90000 13135', 'Pune', null)$$,
  '23514', 'a malformed email is refused');
select tests.throws_ok(
  $$select identity.submit_tenant_signup('Ok Name', 'UTC', 'Asha', 'bad-phone@dup-guard.example', 'call me', 'Pune', null)$$,
  '23514', 'a phone that is not digits is refused');
select tests.ok(
  tests.signup_count('blank-name@dup-guard.example') = 0
  and tests.signup_count('not-an-email') = 0
  and tests.signup_count('bad-phone@dup-guard.example') = 0,
  'invalid input leaves no request row');

-- Date edge: rows older than 24h do not count toward the per-source cap; a very old pending row still matches.
select identity.submit_tenant_signup('Old Source 1', 'UTC', 'Asha', 'old1@dup-guard.example', '+91 90000 14141', 'Pune', 'src-old-dup');
select identity.submit_tenant_signup('Old Source 2', 'UTC', 'Asha', 'old2@dup-guard.example', '+91 90000 14142', 'Pune', 'src-old-dup');
select identity.submit_tenant_signup('Old Source 3', 'UTC', 'Asha', 'old3@dup-guard.example', '+91 90000 14143', 'Pune', 'src-old-dup');
select tests.as_superuser();
alter table identity.tenant_signup_requests disable trigger tenant_signup_requests_audit_columns;
update identity.tenant_signup_requests
   set created_on = timestamptz '1999-12-31 23:00+00'
 where source_hash = 'src-old-dup';
alter table identity.tenant_signup_requests enable trigger tenant_signup_requests_audit_columns;
select tests.as_anon();
select tests.ok(
  identity.submit_tenant_signup('Old Source 4', 'UTC', 'Asha', 'old4@dup-guard.example', '+91 90000 14144', 'Pune', 'src-old-dup') is not null,
  'requests older than 24 hours do not count toward the per-source cap');
select identity.submit_tenant_signup('Old Source 1 Clinic', 'Pacific/Pago_Pago', 'Bea', 'old1b@dup-guard.example', '+91 90000 14145', 'Pune', null);
select tests.ok(
  (select possible_duplicate from tests.signup_row('old1b@dup-guard.example')),
  'a pending request filed in 1999 still matches; the hospital time zone does not hide it');
select identity.submit_tenant_signup('New Source 1', 'UTC', 'Asha', 'new1@dup-guard.example', '+91 90000 15151', 'Pune', 'src-new-dup');
select identity.submit_tenant_signup('New Source 2', 'UTC', 'Asha', 'new2@dup-guard.example', '+91 90000 15152', 'Pune', 'src-new-dup');
select identity.submit_tenant_signup('New Source 3', 'UTC', 'Asha', 'new3@dup-guard.example', '+91 90000 15153', 'Pune', 'src-new-dup');
select tests.throws_ok(
  $$select identity.submit_tenant_signup('New Source 4', 'UTC', 'Asha', 'new4@dup-guard.example', '+91 90000 15154', 'Pune', 'src-new-dup')$$,
  '54000', 'three requests from one source inside 24 hours still block the fourth');

-- Global pending cap (serialized by the signup:queue lock).
select tests.as_superuser();
do $body$
declare
  v_i int := 0;
  v_pending int;
begin
  loop
    select count(*) into v_pending from identity.tenant_signup_requests where status = 'pending' and not is_deleted;
    exit when v_pending >= 200;
    v_i := v_i + 1;
    perform identity.submit_tenant_signup(
      'Queue ' || v_i, 'UTC', 'Queue Contact',
      'q' || v_i || '@dup-queue.example',
      '+1555' || lpad(v_i::text, 4, '0'),
      'Pune', null);
  end loop;
end
$body$;
select tests.as_anon();
select tests.throws_ok(
  $$select identity.submit_tenant_signup('Queue Full Hospital', 'UTC', 'Queue Contact', 'qfull@dup-queue.example', '+15559999', 'Pune', null)$$,
  '54000', 'the 200 pending cap still refuses another request');
select tests.ok(
  tests.signup_count('qfull@dup-queue.example') = 0,
  'a request refused because the queue is full is not stored');

-- Audit columns on the new snapshot fields (the table already audits every update).
select tests.as_superuser();
select tests.ok(
  (select created_by = '00000000-0000-4000-8000-00000000005e' and updated_by is not null
     from tests.signup_row('marble-b@dup-guard.example')),
  'a flagged request still stamps audit columns');
select tests.ok(
  (select count(*) >= 1 from audit.audit_log
    where table_name = 'tenant_signup_requests' and action = 'UPDATE'),
  'linking a possible duplicate updates the earlier request and writes the audit log');

rollback;
