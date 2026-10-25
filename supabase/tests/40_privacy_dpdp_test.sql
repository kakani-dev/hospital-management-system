-- DPDP consent ledger, notices, rights requests, and cross-tenant denial.
begin;

select tests.as_superuser();

select tests.ok(
  (select not rolcanlogin and not rolinherit from pg_roles where rolname = 'hms_svc_privacy')
  and not pg_has_role('hms_svc_privacy', 'authenticated', 'member')
  and pg_has_role('hms_svc_privacy', 'anon', 'member')
  and pg_has_role('hms_privacy_login', 'hms_svc_privacy', 'member')
  and not pg_has_role('hms_privacy_login', 'hms_svc_patients', 'member')
  and not pg_has_role('hms_patients_login', 'hms_svc_privacy', 'member'),
  'privacy group role is NOLOGIN NOINHERIT, member of anon, and only its own login is a member');

select tests.ok(
  has_table_privilege('hms_svc_privacy', 'privacy.consent_notice', 'select')
  and not has_table_privilege('hms_svc_privacy', 'privacy.consent_notice', 'insert')
  and not has_table_privilege('hms_svc_privacy', 'privacy.consent_notice', 'update')
  and not has_table_privilege('hms_svc_privacy', 'privacy.consent_notice', 'delete')
  and not has_table_privilege('hms_svc_privacy', 'privacy.consent_event', 'update')
  and not has_table_privilege('hms_svc_privacy', 'privacy.consent_event', 'delete')
  and not has_table_privilege('hms_svc_privacy', 'privacy.code_seq', 'select')
  and not has_table_privilege('hms_svc_privacy', 'privacy.command_receipt', 'select')
  and not has_table_privilege('hms_svc_patients', 'privacy.consent_notice', 'select')
  and not has_table_privilege('hms_svc_privacy', 'patient.patients', 'select')
  and not has_table_privilege('hms_svc_privacy', 'billing.bill', 'select')
  and not has_function_privilege('hms_svc_patients', 'privacy.consent_allows_v1(uuid, uuid, text)', 'execute')
  and has_function_privilege('hms_svc_privacy', 'privacy.consent_allows_v1(uuid, uuid, text)', 'execute')
  and not has_function_privilege('hms_svc_privacy', 'privacy.note_patient_merge_v1(uuid, uuid, uuid)', 'execute')
  and has_function_privilege('service_role', 'privacy.note_patient_merge_v1(uuid, uuid, uuid)', 'execute')
  and has_schema_privilege('anon', 'privacy', 'usage')
  and has_function_privilege('anon', 'privacy.public_consent_preview(text)', 'execute')
  and has_function_privilege('anon', 'privacy.submit_public_consent(text, jsonb)', 'execute')
  and not has_function_privilege('anon', 'privacy.create_notice(uuid, uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'privacy.consent_allows_v1(uuid, uuid, text)', 'execute')
  and not has_table_privilege('anon', 'privacy.consent_notice', 'select')
  and not has_table_privilege('anon', 'privacy.consent_event', 'select'),
  'privacy reads its own tables through RLS and cannot read another service');

insert into auth.users (id, email, role, aud) values
  ('0a000000-0000-4000-8000-0000000000e1', 'privacy-second@alpha.example', 'authenticated', 'authenticated'),
  ('0a000000-0000-4000-8000-0000000000e2', 'cashier@alpha.example', 'authenticated', 'authenticated');
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-0000000000e1', null, 'tenant_admin', 'active'),
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-0000000000e2', 'a1111111-0000-4000-8000-000000000001', 'billing', 'active');

-- Alpha admin, through the privacy login (not the table owner, so permission checks apply).
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text,
  true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
set local session authorization hms_privacy_login;
set local role hms_svc_privacy;

select tests.throws_ok(
  $$select privacy.create_notice(
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01',
      '{"code":"N-1","language":"en","title":"T","body":"This body is long enough to pass the length check easily.","purposes":["reminders"]}'::jsonb)$$,
  'P0001',
  'a client cannot supply a notice code');

select privacy.create_notice(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01',
  jsonb_build_object(
    'language', 'en',
    'title', 'How Alpha uses health information',
    'body', 'Alpha Hospital tells you what it uses your health information for. Treatment and billing do not need a separate tick.',
    'purposes', jsonb_build_array('reminders', 'marketing', 'research', 'abdm_share')));

select tests.ok(
  (select version = 1 and published_at is null and language_code = 'en'
     from privacy.consent_notice
    where tenant_id = '11111111-1111-4111-8111-111111111111' and title = 'How Alpha uses health information'),
  'the first English notice is version 1 and still a draft');

select privacy.create_notice(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01',
  jsonb_build_object(
    'language', 'en',
    'title', 'How Alpha uses health information',
    'body', 'Alpha Hospital tells you what it uses your health information for. Treatment and billing do not need a separate tick.',
    'purposes', jsonb_build_array('reminders', 'marketing', 'research', 'abdm_share')));

select tests.ok(
  (select count(*) = 1 from privacy.consent_notice
    where tenant_id = '11111111-1111-4111-8111-111111111111'),
  'the same idempotency key and body replay the first notice');

select tests.throws_ok(
  $$select privacy.create_notice(
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01',
      '{"language":"hi","title":"Hindi","body":"यह सूचना पर्याप्त लम्बी है ताकि लम्बाई की जाँच पास हो सके।","purposes":["reminders"]}'::jsonb)$$,
  'P0001',
  'the same idempotency key with a different body is refused');

select privacy.publish_notice(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02',
  (select id from privacy.consent_notice where tenant_id = '11111111-1111-4111-8111-111111111111'));

select tests.throws_ok(
  $$select privacy.publish_notice(
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa03',
      (select id from privacy.consent_notice where tenant_id = '11111111-1111-4111-8111-111111111111'))$$,
  'P0001',
  'a published notice cannot be published again');

reset role;
reset session authorization;
select tests.as_superuser();
select tests.throws_ok(
  $$update privacy.consent_notice set title = 'Changed'
     where tenant_id = '11111111-1111-4111-8111-111111111111'$$,
  'P0001',
  'a published notice cannot be edited');
select tests.throws_ok(
  $$delete from privacy.consent_notice where tenant_id = '11111111-1111-4111-8111-111111111111'$$,
  'P0001',
  'a published notice cannot be deleted');

select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@alpha.example')::text,
  true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
set local session authorization hms_privacy_login;
set local role hms_svc_privacy;

select tests.throws_ok(
  $$select privacy.record_consents(
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa10',
      'aa000000-0000-4000-8000-000000000003',
      jsonb_build_object(
        'noticeId', (select id from privacy.consent_notice where tenant_id = '11111111-1111-4111-8111-111111111111'),
        'channel', 'tablet', 'givenBy', 'self', 'subjectIsMinor', true,
        'choices', jsonb_build_array(jsonb_build_object('purposeCode', 'reminders', 'granted', true))))$$,
  'P0001',
  'a child cannot consent for themselves');

select privacy.record_consents(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa11',
  'aa000000-0000-4000-8000-000000000002',
  jsonb_build_object(
    'noticeId', (select id from privacy.consent_notice where tenant_id = '11111111-1111-4111-8111-111111111111'),
    'channel', 'tablet', 'givenBy', 'self', 'subjectIsMinor', false,
    'choices', jsonb_build_array(
      jsonb_build_object('purposeCode', 'reminders', 'granted', true),
      jsonb_build_object('purposeCode', 'marketing', 'granted', false))));

reset role;
reset session authorization;
select tests.as_superuser();
select tests.ok(
  (select count(*) = 1 from messaging.outbox
    where aggregate_type = 'privacy' and event_type = 'consent.granted_v1' and source_service = 'privacy'
      and payload ->> 'purposeCode' = 'reminders'
      and payload ->> 'patientId' = 'aa000000-0000-4000-8000-000000000002')
  and (select count(*) = 1 from messaging.outbox
    where event_type = 'consent.receipt_requested_v1' and source_service = 'privacy'),
  'a grant queues consent.granted_v1 and a receipt request, with no clinical text');

select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
set local session authorization hms_privacy_login;
set local role hms_svc_privacy;

select tests.ok(
  privacy.consent_allows_v1(
    '11111111-1111-4111-8111-111111111111',
    'aa000000-0000-4000-8000-000000000002',
    'reminders')
  and not privacy.consent_allows_v1(
    '11111111-1111-4111-8111-111111111111',
    'aa000000-0000-4000-8000-000000000002',
    'marketing'),
  'the latest grant allows reminders and a refusal does not allow marketing');

select privacy.withdraw_consent(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa12',
  'aa000000-0000-4000-8000-000000000002',
  'reminders',
  '{"channel":"tablet"}'::jsonb);

select tests.ok(
  not privacy.consent_allows_v1(
    '11111111-1111-4111-8111-111111111111',
    'aa000000-0000-4000-8000-000000000002',
    'reminders'),
  'withdrawal is the latest event and consent is no longer allowed');

reset role;
reset session authorization;
select tests.as_superuser();
select tests.throws_ok(
  $$update privacy.consent_event set action = 'grant'$$,
  'P0001',
  'the consent ledger is append-only');
select tests.ok(
  (select count(*) = 1 from messaging.outbox
    where event_type = 'consent.withdrawn_v1' and source_service = 'privacy'
      and payload ->> 'purposeCode' = 'reminders'
      and payload ->> 'patientId' = 'aa000000-0000-4000-8000-000000000002'),
  'withdrawal queues consent.withdrawn_v1 for that purpose');

select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
set local session authorization hms_privacy_login;
set local role hms_svc_privacy;

select privacy.create_rights_request(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa21',
  jsonb_build_object(
    'patientId', 'aa000000-0000-4000-8000-000000000002',
    'type', 'access',
    'details', 'Please send me a copy of the information you hold.',
    'channel', 'desk'));

select tests.ok(
  (select code ~ '^DPR-[0-9]{4}-00001$'
      and due_at between received_at + interval '89 days' and received_at + interval '91 days'
     from privacy.rights_request
    where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'access'),
  'an access request gets a DPR number and is due in 90 days');

select privacy.verify_rights_request(
  '11111111-1111-4111-8111-111111111111',
  (select id from privacy.rights_request
    where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'access'));

select tests.ok(
  (privacy.access_export(
      '11111111-1111-4111-8111-111111111111',
      (select id from privacy.rights_request
        where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'access'))
    -> 'patient' ->> 'mrn') = 'ALP-0002'
  and (privacy.access_export(
      '11111111-1111-4111-8111-111111111111',
      (select id from privacy.rights_request
        where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'access'))::text)
    not like '%+1-555-0102%',
  'the access summary uses the published patient read and does not include a phone number');

-- Erasure of Ravi (no open visit). The same approver is not enough.
select privacy.create_rights_request(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa22',
  jsonb_build_object(
    'patientId', 'aa000000-0000-4000-8000-000000000002',
    'type', 'erasure',
    'details', 'Please erase the contact copies you hold about me.',
    'channel', 'desk'));
select privacy.verify_rights_request(
  '11111111-1111-4111-8111-111111111111',
  (select id from privacy.rights_request
    where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'erasure'
      and patient_id = 'aa000000-0000-4000-8000-000000000002'));
select privacy.approve_erasure(
  '11111111-1111-4111-8111-111111111111',
  (select id from privacy.rights_request
    where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'erasure'
      and patient_id = 'aa000000-0000-4000-8000-000000000002'));
select tests.throws_ok(
  $$select privacy.execute_erasure(
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa23',
      (select id from privacy.rights_request
        where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'erasure'
          and patient_id = 'aa000000-0000-4000-8000-000000000002'))$$,
  'P0001',
  'the person who verifies cannot be the only approver');

select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-0000000000e1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-0000000000e1', true);
select privacy.approve_erasure(
  '11111111-1111-4111-8111-111111111111',
  (select id from privacy.rights_request
    where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'erasure'
      and patient_id = 'aa000000-0000-4000-8000-000000000002'));

select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
select privacy.execute_erasure(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa23',
  (select id from privacy.rights_request
    where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'erasure'
      and patient_id = 'aa000000-0000-4000-8000-000000000002'));

select tests.ok(
  (select status = 'fulfilled' and details = '[erased]'
     from privacy.rights_request
    where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'erasure'
      and patient_id = 'aa000000-0000-4000-8000-000000000002')
  and (select action = 'anonymised' from privacy.erasure_item
    where data_category = 'contact_copies'
      and request_id = (select id from privacy.rights_request
        where request_type = 'erasure' and patient_id = 'aa000000-0000-4000-8000-000000000002'))
  and (select action = 'retained' and retention_policy_code = 'nmc_opd_3y' from privacy.erasure_item
    where data_category = 'clinical_opd'
      and request_id = (select id from privacy.rights_request
        where request_type = 'erasure' and patient_id = 'aa000000-0000-4000-8000-000000000002'))
  and (select action = 'retained' and retention_policy_code = 'gst_72m' from privacy.erasure_item
    where data_category = 'billing_gst'
      and request_id = (select id from privacy.rights_request
        where request_type = 'erasure' and patient_id = 'aa000000-0000-4000-8000-000000000002')),
  'erasure clears the request text, keeps the consent ledger, and retains OPD and GST');

-- Asha has a booked visit, so erasure is held and nothing is anonymised.
select privacy.create_rights_request(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa24',
  jsonb_build_object(
    'patientId', 'aa000000-0000-4000-8000-000000000001',
    'type', 'erasure',
    'details', 'Please erase what you hold. I still have a visit booked.',
    'channel', 'desk'));
select privacy.verify_rights_request(
  '11111111-1111-4111-8111-111111111111',
  (select id from privacy.rights_request
    where patient_id = 'aa000000-0000-4000-8000-000000000001' and request_type = 'erasure'));
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-0000000000e1', true);
select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-0000000000e1', 'role', 'authenticated')::text, true);
select privacy.approve_erasure(
  '11111111-1111-4111-8111-111111111111',
  (select id from privacy.rights_request
    where patient_id = 'aa000000-0000-4000-8000-000000000001' and request_type = 'erasure'));
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select privacy.execute_erasure(
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa25',
  (select id from privacy.rights_request
    where patient_id = 'aa000000-0000-4000-8000-000000000001' and request_type = 'erasure'));

select tests.ok(
  (select status = 'held' and details <> '[erased]'
     from privacy.rights_request
    where patient_id = 'aa000000-0000-4000-8000-000000000001' and request_type = 'erasure')
  and (select bool_and(action = 'retained') from privacy.erasure_item i
    join privacy.rights_request r on r.tenant_id = i.tenant_id and r.id = i.request_id
    where r.patient_id = 'aa000000-0000-4000-8000-000000000001'),
  'an open visit holds erasure and retains every category');

reset role;
reset session authorization;
select tests.as_superuser();
select tests.ok(
  (select count(*) = 1 from messaging.outbox
    where event_type = 'patient.erased_v1'
      and payload ->> 'patientId' = 'aa000000-0000-4000-8000-000000000002')
  and not exists (select 1 from messaging.outbox
    where event_type = 'patient.erased_v1'
      and payload ->> 'patientId' = 'aa000000-0000-4000-8000-000000000001'),
  'patient.erased_v1 is emitted only when contact copies were cleared');

-- Due soon: pull the access request inside the 10-day window and list it.
update privacy.rights_request
   set due_at = clock_timestamp() + interval '5 days', due_soon_emitted = false
 where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'access';
select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
set local session authorization hms_privacy_login;
set local role hms_svc_privacy;
select privacy.list_rights_requests('11111111-1111-4111-8111-111111111111', null);
reset role;
reset session authorization;
select tests.as_superuser();
select tests.ok(
  (select count(*) = 1 from messaging.outbox where event_type = 'rights_request.due_soon_v1' and source_service = 'privacy')
  and (select due_soon_emitted from privacy.rights_request
    where tenant_id = '11111111-1111-4111-8111-111111111111' and request_type = 'access'),
  'listing the queue emits due_soon once when a request is due within 10 days');

-- Public link. The token is not stored, and the preview has no name or MRN.
select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
set local session authorization hms_privacy_login;
set local role hms_svc_privacy;
create temporary table t_link (body jsonb) on commit drop;
insert into t_link
select privacy.create_consent_link(
  '11111111-1111-4111-8111-111111111111',
  'aa000000-0000-4000-8000-000000000003');
select tests.ok(
  (select token_hash <> substring(body ->> 'path' from '([0-9a-f]{64})$')
     from privacy.consent_link, t_link
    where patient_id = 'aa000000-0000-4000-8000-000000000003'),
  'only the hash of the consent link is stored');

select tests.ok(
  (select privacy.public_consent_preview(substring(body ->> 'path' from '([0-9a-f]{64})$'))::text
     from t_link) not like '%Meera%'
  and (select privacy.public_consent_preview(substring(body ->> 'path' from '([0-9a-f]{64})$'))::text
     from t_link) not like '%ALP-%'
  and (select privacy.public_consent_preview(substring(body ->> 'path' from '([0-9a-f]{64})$')) ->> 'title'
     from t_link) = 'How Alpha uses health information',
  'the public preview shows the notice and no patient name or MRN');

select tests.throws_ok(
  $$select privacy.submit_public_consent(
      (select substring(body ->> 'path' from '([0-9a-f]{64})$') from t_link),
      '{"tenantId":"11111111-1111-4111-8111-111111111111","choices":[{"purposeCode":"reminders","granted":true}]}'::jsonb)$$,
  'P0001',
  'a public submission cannot name the hospital');

select privacy.submit_public_consent(
  (select substring(body ->> 'path' from '([0-9a-f]{64})$') from t_link),
  '{"choices":[{"purposeCode":"reminders","granted":true}]}'::jsonb);
select tests.throws_ok(
  $$select privacy.public_consent_preview(
      (select substring(body ->> 'path' from '([0-9a-f]{64})$') from t_link))$$,
  'P0001',
  'a used link is expired');

-- Reception can record and cannot erase or publish. A cashier cannot look. A doctor can look.
select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated', 'email', 'reception@alpha.example')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000002', true);
select tests.throws_ok(
  $$select privacy.execute_erasure(
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa30',
      (select id from privacy.rights_request
        where patient_id = 'aa000000-0000-4000-8000-000000000001' and request_type = 'erasure'))$$,
  '42501',
  'reception cannot erase');
select tests.throws_ok(
  $$select privacy.create_notice(
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa31',
      '{"language":"en","title":"Nope","body":"This body is long enough to pass the length check easily.","purposes":["reminders"]}'::jsonb)$$,
  '42501',
  'reception cannot publish a notice');

select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-0000000000e2', 'role', 'authenticated', 'email', 'cashier@alpha.example')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-0000000000e2', true);
select tests.throws_ok(
  $$select privacy.list_rights_requests('11111111-1111-4111-8111-111111111111', null)$$,
  '42501',
  'a cashier cannot see data-principal requests');

select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0d000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'consultant@shared.example')::text, true);
select set_config('request.jwt.claim.sub', '0d000000-0000-4000-8000-000000000001', true);
select tests.ok(
  jsonb_typeof(privacy.list_consents(
    '11111111-1111-4111-8111-111111111111',
    'aa000000-0000-4000-8000-000000000003')) = 'object',
  'a doctor can read consent');
select tests.throws_ok(
  $$select privacy.record_consents(
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa32',
      'aa000000-0000-4000-8000-000000000003',
      jsonb_build_object(
        'noticeId', (select id from privacy.consent_notice where tenant_id = '11111111-1111-4111-8111-111111111111'),
        'channel', 'tablet', 'givenBy', 'self',
        'choices', jsonb_build_array(jsonb_build_object('purposeCode', 'research', 'granted', true))))$$,
  '42501',
  'a doctor cannot record consent');

-- Cross-tenant: Beta admin.
select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0b000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'email', 'admin@beta.example')::text, true);
select set_config('request.jwt.claim.sub', '0b000000-0000-4000-8000-000000000001', true);
select tests.ok(
  (select count(*) = 0 from privacy.consent_notice)
  and (select count(*) = 0 from privacy.consent_event)
  and (select count(*) = 0 from privacy.rights_request),
  'RLS hides Alpha consent and requests from Beta');
select tests.throws_ok(
  $$select privacy.consent_allows_v1(
      '11111111-1111-4111-8111-111111111111',
      'aa000000-0000-4000-8000-000000000002',
      'reminders')$$,
  'P0002',
  'consent_allows_v1 refuses another hospital');
select tests.throws_ok(
  $$select privacy.list_consents(
      '11111111-1111-4111-8111-111111111111',
      'aa000000-0000-4000-8000-000000000002')$$,
  '42501',
  'Beta cannot list Alpha consent');

-- Merge alias combines history. The patients service is not granted the function.
reset role;
reset session authorization;
select tests.as_superuser();
select set_config('request.jwt.claims',
  jsonb_build_object('sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
select privacy.note_patient_merge_v1(
  '11111111-1111-4111-8111-111111111111',
  'aa000000-0000-4000-8000-000000000003',
  'aa000000-0000-4000-8000-000000000002');
set local session authorization hms_privacy_login;
set local role hms_svc_privacy;
select tests.ok(
  (privacy.list_consents(
      '11111111-1111-4111-8111-111111111111',
      'aa000000-0000-4000-8000-000000000002') -> 'history')::text like '%aa000000-0000-4000-8000-000000000003%',
  'a merge alias shows the retired chart on the survivor history');

reset role;
reset session authorization;
rollback;
