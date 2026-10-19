-- Level 1: hospital sign-up requests, platform console functions, invite links, tenant suspension.
-- Migration 20261019090000_level1_platform_onboarding.sql. Self-contained (creates its own
-- synthetic operator, so it also runs on the Supabase-stack CI job without the local seed).
begin;

select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e100000-0000-4000-8000-000000000001', 'op-l1@medicore.example', 'authenticated', 'authenticated'),
  ('0e100000-0000-4000-8000-000000000002', 'new-admin@l1-hospital.example', 'authenticated', 'authenticated'),
  ('0e100000-0000-4000-8000-000000000003', 'new-nurse@l1-hospital.example', 'authenticated', 'authenticated');
select tests.ok(identity.grant_platform_admin('OP-L1@medicore.example') = '0e100000-0000-4000-8000-000000000001',
  'grant_platform_admin grants an existing account by email (case-insensitive)');
select tests.throws_ok($$select identity.grant_platform_admin('nobody@nowhere.example')$$, 'P0002',
  'grant_platform_admin needs an existing auth user');
select tests.ok(
  not has_function_privilege('authenticated', 'identity.grant_platform_admin(text)', 'execute')
  and not has_function_privilege('anon', 'identity.grant_platform_admin(text)', 'execute')
  and not has_function_privilege('service_role', 'identity.grant_platform_admin(text)', 'execute'),
  'grant_platform_admin is owner-only (ops script), not reachable from clients or the API');
select tests.ok(
  not has_table_privilege('authenticated', 'identity.tenant_signup_requests', 'select')
  and not has_table_privilege('anon', 'identity.tenant_signup_requests', 'insert')
  and not has_table_privilege('authenticated', 'identity.invite_links', 'select')
  and not has_table_privilege('authenticated', 'identity.tenant_status_changes', 'select'),
  'the new tables are reachable only through the definer functions');

select tests.ok(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'identity' and has_function_privilege('anon', p.oid, 'execute'))
  = array['preview_invite_link', 'submit_tenant_signup'],
  'anon can execute exactly two identity functions: submit_tenant_signup and preview_invite_link');

-- ========================================================== public sign-up ==
select tests.as_anon();
select tests.ok(identity.submit_tenant_signup('L1 Synthetic Hospital', 'Asia/Calcutta', 'Asha Admin', 'New-Admin@l1-hospital.example',
  '+91 555 0100 200', 'Pune', 'src-a') is not null, 'anonymous visitors can submit a hospital registration');
select tests.ok(identity.submit_tenant_signup('L1 Synthetic Hospital', 'Asia/Kolkata', 'Asha Admin', 'new-admin@l1-hospital.example',
  '+91 555 0100 200', 'Pune', 'src-a') is null, 'a second pending request for the same email is absorbed (no new row, same 202)');
select tests.throws_ok($$select identity.submit_tenant_signup('X Hospital', 'IST', 'Asha', 'x@l1.example', '+91 555 0100', 'Pune', 'src-b')$$,
  '22023', 'the time zone is required and must be IANA');
select tests.throws_ok($$select identity.submit_tenant_signup('X Hospital', 'Asia/Kolkata', 'Asha', 'not-an-email', '+91 555 0100', 'Pune', 'src-b')$$,
  '23514', 'contact email format is enforced');
select tests.throws_ok($$select identity.submit_tenant_signup('X Hospital', 'Asia/Kolkata', 'Asha', 'x@l1.example', 'call me', 'Pune', 'src-b')$$,
  '23514', 'phone format is enforced');
select identity.submit_tenant_signup('Spam 1', 'UTC', 'Spammer', 'spam1@l1.example', '+1 555 0101', 'Nowhere', 'src-spam');
select identity.submit_tenant_signup('Spam 2', 'UTC', 'Spammer', 'spam2@l1.example', '+1 555 0102', 'Nowhere', 'src-spam');
select identity.submit_tenant_signup('Spam 3', 'UTC', 'Spammer', 'spam3@l1.example', '+1 555 0103', 'Nowhere', 'src-spam');
select tests.throws_ok($$select identity.submit_tenant_signup('Spam 4', 'UTC', 'Spammer', 'spam4@l1.example', '+1 555 0104', 'Nowhere', 'src-spam')$$,
  '54000', 'at most 3 registrations per source per 24 h (rate_limited)');
select tests.throws_ok($$select * from identity.platform_list_signups()$$, '42501', 'anonymous callers cannot list requests');

select tests.as_superuser();
create temporary table t_req on commit drop as select hospital_name, id from identity.tenant_signup_requests;
grant select on t_req to public;
select tests.ok(
  (select time_zone = 'Asia/Kolkata' and status = 'pending' and contact_email = 'new-admin@l1-hospital.example'
     and created_by = '00000000-0000-4000-8000-00000000005e' and tenant_id is null
   from identity.tenant_signup_requests where hospital_name = 'L1 Synthetic Hospital'),
  'the request is stored pending, zone canonical, email lower-cased, audit columns stamped (system actor)');
select tests.ok(not exists (select 1 from identity.tenants where name = 'L1 Synthetic Hospital'),
  'a pending request creates NO tenant');
select tests.ok(not exists (select 1 from identity.memberships where user_id = '0e100000-0000-4000-8000-000000000002'),
  'a pending request creates NO membership for the contact');

-- pending contact (has an account) has zero access
select tests.authenticate_as('new-admin@l1-hospital.example');
select tests.ok(not exists (select 1 from identity.current_tenant_ids()), 'pending applicant: current_tenant_ids() is empty');
select tests.ok(not exists (select 1 from identity.my_memberships()), 'pending applicant: no memberships');
select tests.ok(not exists (select 1 from identity.tenants), 'pending applicant: sees no tenant rows');
select tests.ok(not exists (select 1 from patient.patients), 'pending applicant: sees no patients');
select tests.throws_ok($$select * from identity.platform_list_signups()$$, '42501', 'an applicant is not a platform admin');

-- ============================================================== operator ==
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$select * from identity.platform_list_tenants()$$, '42501', 'a tenant admin cannot use the platform console (list)');
select tests.throws_ok($$select identity.platform_set_tenant_status('22222222-2222-4222-8222-222222222222', 'suspended', 'cross-tenant attack')$$,
  '42501', 'a tenant admin cannot suspend another hospital');

select tests.authenticate_as('op-l1@medicore.example');
select tests.ok((select count(*) >= 1 from identity.platform_list_signups('pending') where hospital_name = 'L1 Synthetic Hospital'),
  'the operator sees the pending request');
create temporary table t_appr on commit drop as
  select * from identity.platform_approve_signup(
    (select id from t_req where hospital_name = 'L1 Synthetic Hospital'), 'l1-synth');
grant select on t_appr to public;
select tests.ok((select count(*) = 1 and bool_and(length(token) = 64) from t_appr), 'approve returns the tenant and a one-time invite token');
select tests.throws_ok($$select * from identity.platform_approve_signup(
    (select id from t_req where hospital_name = 'L1 Synthetic Hospital'), 'l1-synth-2')$$,
  '55000', 'a decided request cannot be approved twice');
select tests.throws_ok($$select identity.platform_reject_signup((select id from t_req where hospital_name = 'Spam 1'), 'no')$$,
  '22023', 'rejecting needs a reason');
select identity.platform_reject_signup((select id from t_req where hospital_name = 'Spam 1'), 'Not a hospital (synthetic spam)');
select tests.ok((select status = 'rejected' and decision_reason = 'Not a hospital (synthetic spam)'
                 from identity.platform_list_signups('rejected') where hospital_name = 'Spam 1'), 'reject records the reason');
select tests.ok(not exists (select 1 from patient.patients), 'the operator gets NO implicit tenant access: no patient rows');
select tests.ok(not exists (select 1 from identity.memberships), 'the operator sees no memberships through RLS');
select tests.ok(not exists (select 1 from identity.current_tenant_ids()), 'the operator has no tenant grant');
select tests.ok((select branch_count = 1 and user_count = 0 and pending_invites = 1 and time_zone = 'Asia/Kolkata' and status = 'active'
                 from identity.platform_list_tenants('l1-synth')), 'hospital list: counts, zone and status (metadata only)');

select tests.as_superuser();
select tests.ok(
  (select r.status = 'approved' and r.tenant_id = t.tenant_id and r.decided_by = '0e100000-0000-4000-8000-000000000001'
     and r.invite_link_id = t.invite_link_id
   from identity.tenant_signup_requests r, t_appr t where r.hospital_name = 'L1 Synthetic Hospital'),
  'approval links the request to the new tenant and invite; decided_by = the operator');
select tests.ok(
  (select tn.time_zone = 'Asia/Kolkata' and tn.created_by = '0e100000-0000-4000-8000-000000000001' from identity.tenants tn, t_appr t where tn.id = t.tenant_id),
  'the tenant is created by create_tenant with the requested zone');
select tests.ok(
  (select l.token_hash <> convert_to(t.token, 'UTF8') and l.token_hash = sha256(convert_to(t.token, 'UTF8')) and l.role = 'tenant_admin'
     and l.status = 'pending' and l.source = 'signup_approval'
   from identity.invite_links l, t_appr t where l.id = t.invite_link_id),
  'only the SHA-256 of the token is stored');
create temporary table t_branch on commit drop as select b.id from identity.branches b, t_appr t where b.tenant_id = t.tenant_id;
grant select on t_branch to public;
select tests.ok(not exists (select 1 from identity.memberships m, t_appr t where m.tenant_id = t.tenant_id),
  'approval alone creates no membership (access starts when the admin claims the link)');

-- ============================================================ invite links ==
select tests.authenticate_as('new-admin@l1-hospital.example');
select tests.ok(not exists (select 1 from identity.current_tenant_ids()), 'approved but unclaimed: still zero access');
select tests.authenticate_as('new-nurse@l1-hospital.example');
select tests.throws_ok(format($$select * from identity.claim_invite_link(%L)$$, (select token from t_appr)), '42501',
  'a link cannot be claimed by a different email');
select tests.as_anon();
select tests.ok((select tenant_name = 'L1 Synthetic Hospital' and email_hint = 'n********@l1-hospital.example' and role = 'tenant_admin'
                 from identity.preview_invite_link((select token from t_appr))), 'anonymous preview shows the hospital and a masked email');
select tests.ok(not exists (select 1 from identity.preview_invite_link('not-a-token')), 'an unknown token previews nothing');
select tests.authenticate_as('new-admin@l1-hospital.example');
select tests.ok((select role = 'tenant_admin' and branch_id is null from identity.claim_invite_link((select token from t_appr))),
  'the invitee claims the link and becomes tenant_admin');
select tests.ok((select count(*) = 1 from identity.current_tenant_ids()), 'after claiming: access to exactly the new tenant');
select tests.throws_ok(format($$select * from identity.claim_invite_link(%L)$$, (select token from t_appr)), 'P0002', 'a link is single-use');

-- tenant admin issues a staff link; cross-tenant checks
create temporary table t_staff on commit drop as
  select * from identity.create_member_invite_link((select tenant_id from t_appr), 'New-Nurse@l1-hospital.example', 'nurse',
    (select id from t_branch));
grant select on t_staff to public;
select tests.ok((select count(*) = 2 and bool_or(status = 'pending' and role = 'nurse' and email = 'new-nurse@l1-hospital.example')
                   and bool_or(status = 'claimed' and role = 'tenant_admin')
                 from identity.list_member_invite_links((select tenant_id from t_appr))), 'the admin lists the hospital''s links (pending + claimed)');
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok(format($$select * from identity.list_member_invite_links(%L)$$, (select tenant_id from t_appr)), '42501',
  'cross-tenant: another hospital''s admin cannot list its invites');
select tests.throws_ok(format($$select identity.revoke_invite_link(%L, %L)$$, (select tenant_id from t_appr), (select id from t_staff)), '42501',
  'cross-tenant: another hospital''s admin cannot revoke its invites');
select tests.throws_ok(format($$select identity.revoke_invite_link('11111111-1111-4111-8111-111111111111', %L)$$, (select id from t_staff)), 'P0002',
  'cross-tenant: an id from another tenant is not found under your own tenant');
select tests.throws_ok(format($$select * from identity.create_member_invite_link('11111111-1111-4111-8111-111111111111', 'x@l1.example', 'nurse', %L)$$,
  (select id from t_branch)), 'P0002',
  'cross-tenant: a link cannot point at another tenant''s branch');
select tests.authenticate_as('new-nurse@l1-hospital.example');
select tests.ok((select role = 'nurse' and branch_id is not null from identity.claim_invite_link((select token from t_staff))),
  'staff claim a branch-scoped link');

-- ============================================================ suspension ==
select tests.authenticate_as('op-l1@medicore.example');
select tests.throws_ok(format($$select identity.platform_set_tenant_status(%L, 'suspended', '')$$, (select tenant_id from t_appr)), '22023',
  'suspension needs a reason');
select identity.platform_set_tenant_status((select tenant_id from t_appr), 'suspended', 'Unpaid synthetic invoice');
select tests.ok((select status = 'suspended' and status_reason = 'Unpaid synthetic invoice' from identity.platform_list_tenants('l1-synth')),
  'suspended with the reason on record');
select tests.authenticate_as('new-admin@l1-hospital.example');
select tests.ok(not exists (select 1 from identity.current_tenant_ids()), 'suspended tenant: its admin has no grant');
select tests.ok(identity.my_tenant_grant_v1((select tenant_id from t_appr)) is null, 'suspended tenant: my_tenant_grant_v1 is null');
select tests.throws_ok(format($$select identity.set_active_context(%L, null)$$, (select tenant_id from t_appr)), '42501',
  'suspended tenant: switching into it is refused');
select tests.authenticate_as('op-l1@medicore.example');
select tests.throws_ok(format($$select identity.platform_set_tenant_status(%L, 'suspended', 'again')$$, (select tenant_id from t_appr)), '55000',
  'suspending twice -> 55000');
select identity.platform_set_tenant_status((select tenant_id from t_appr), 'active', 'Invoice settled (synthetic)');
select tests.ok((select count(*) = 2 from identity.platform_tenant_history((select tenant_id from t_appr))), 'status history has both changes');
select tests.authenticate_as('new-admin@l1-hospital.example');
select tests.ok(identity.my_tenant_grant_v1((select tenant_id from t_appr)) is not null, 'reactivated: access is back');

-- direct creation by the operator
select tests.authenticate_as('op-l1@medicore.example');
select tests.ok((select count(*) = 1 from identity.platform_create_tenant('l1-direct', 'L1 Direct (synthetic)', 'Europe/London', 'boss@l1-direct.example')),
  'the operator creates a tenant directly with a first-admin link');
select tests.throws_ok($$select * from identity.platform_create_tenant('l1-nozone', 'No zone (synthetic)', null, 'boss@l1.example')$$, '22023',
  'direct creation requires a zone');
select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$select * from identity.platform_create_tenant('l1-evil', 'Evil (synthetic)', 'UTC', 'x@evil.example')$$, '42501',
  'a tenant admin cannot create tenants through the console');

select tests.as_superuser();
select tests.ok((select count(*) >= 3 from audit.audit_log where table_name in ('tenant_signup_requests', 'invite_links', 'tenant_status_changes')),
  'the new tables write the audit log');

rollback;
