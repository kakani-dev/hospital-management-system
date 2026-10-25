-- Product email: transactional enqueue, no PHI in the outbox payload, hms_mailer only, idempotent receipts.
-- Migration 20261022090000_identity_email_delivery.sql.
begin;

select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e310000-0000-4000-8000-000000000001', 'op-mail@medicore.example', 'authenticated', 'authenticated'),
  ('0e310000-0000-4000-8000-000000000002', 'ack@email-test.example', 'authenticated', 'authenticated'),
  ('0e310000-0000-4000-8000-000000000003', 'nurse@email-test.example', 'authenticated', 'authenticated');
select identity.grant_platform_admin('op-mail@medicore.example');

select tests.ok(
  (select not rolcanlogin and not rolinherit and not rolbypassrls and not rolsuper from pg_roles where rolname = 'hms_mailer'),
  'hms_mailer is NOLOGIN NOINHERIT, no BYPASSRLS');
select tests.ok(
  not has_table_privilege('hms_mailer', 'identity.pending_emails', 'SELECT')
  and not has_table_privilege('hms_mailer', 'messaging.outbox', 'SELECT')
  and not has_table_privilege('hms_mailer', 'messaging.email_send_receipts', 'SELECT')
  and not has_table_privilege('authenticated', 'identity.pending_emails', 'SELECT')
  and not has_table_privilege('anon', 'identity.pending_emails', 'SELECT'),
  'pending emails and receipts are not readable by the mailer role or by clients');
select tests.ok(
  not has_function_privilege('hms_dispatcher', 'messaging.claim_email_outbox(text, integer, interval)', 'execute')
  and not has_function_privilege('anon', 'messaging.claim_email_outbox(text, integer, interval)', 'execute')
  and not has_function_privilege('authenticated', 'identity.enqueue_email(uuid, uuid, text, text, jsonb, uuid)', 'execute')
  and has_function_privilege('hms_mailer', 'messaging.claim_email_outbox(text, integer, interval)', 'execute'),
  'only hms_mailer claims email rows; clients cannot enqueue');

-- ---------------------------------------------------------------- sign-up ----
select tests.as_anon();
select tests.ok(identity.submit_tenant_signup(
  'Email Test Hospital', 'Asia/Kolkata', 'Asha Contact', 'Ack@email-test.example', '+91 555 0190', 'Pune', 'src-mail') is not null,
  'a registration is accepted');
select tests.ok(identity.submit_tenant_signup(
  'Email Test Hospital', 'Asia/Kolkata', 'Asha Contact', 'ack@email-test.example', '+91 555 0190', 'Pune', 'src-mail') is null,
  'a duplicate pending registration is absorbed');

select tests.as_superuser();
select tests.ok(
  (select count(*) = 1 from messaging.outbox o
    join identity.pending_emails p on p.id = (o.payload ->> 'pending_email_id')::uuid
   where o.event_type = 'email.signup_received' and p.recipient = 'ack@email-test.example'),
  'one acknowledgement is queued, not two');
select tests.ok(
  (select o.source_service = 'identity'
      and array(select jsonb_object_keys(o.payload) order by 1) = array['pending_email_id', 'template_key']
      and o.payload ->> 'template_key' = 'signup_received'
      and o.payload::text not like '%@%'
      and o.payload::text not ilike '%Asha%'
      and o.payload::text not ilike '%Email Test%'
      and o.tenant_id = '00000000-0000-0000-0000-000000000000'
      and p.tenant_id is null
      and p.variables ->> 'hospitalName' = 'Email Test Hospital'
    from messaging.outbox o
    join identity.pending_emails p on p.id = (o.payload ->> 'pending_email_id')::uuid
   where o.event_type = 'email.signup_received' and p.recipient = 'ack@email-test.example'),
  'the acknowledgement payload has no address or name; those stay on pending_emails');

select tests.throws_ok(
  $$insert into messaging.outbox (tenant_id, aggregate_type, aggregate_id, event_type, payload)
    values ('11111111-1111-4111-8111-111111111111', 'email_message', gen_random_uuid(), 'email.invite_link',
            '{"pending_email_id":"00000000-0000-4000-8000-000000000099","template_key":"invite_link","email":"a@b.example"}')$$,
  '22023', 'an address cannot be written into an email outbox payload');

-- ---------------------------------------------------------- approve / reject ----
select tests.authenticate_as('op-mail@medicore.example');
create temporary table t_mail_appr on commit drop as
  select * from identity.platform_approve_signup(
    (select id from identity.platform_list_signups('pending') where hospital_name = 'Email Test Hospital'),
    'email-test');
grant select on t_mail_appr to public;
select identity.submit_tenant_signup('Email Reject Hospital', 'UTC', 'Reject Contact', 'reject@email-test.example', '+1 555 0191', 'NYC', 'src-mail-2');
select identity.platform_reject_signup(
  (select id from identity.platform_list_signups('pending') where hospital_name = 'Email Reject Hospital'),
  'synthetic-reject-reason-zz');

select tests.as_superuser();
select tests.ok(
  (select count(*) = 1 from messaging.outbox where event_type = 'email.signup_approved' and aggregate_id in (
     select id from identity.tenant_signup_requests where contact_email = 'ack@email-test.example'))
  and not exists (
    select 1 from messaging.outbox o
    join identity.pending_emails p on p.id = (o.payload ->> 'pending_email_id')::uuid
    where o.event_type = 'email.invite_link' and p.invite_link_id = (select invite_link_id from t_mail_appr)),
  'approval queues one email that carries the invite, not a second invite email');
select tests.ok(
  (select o.payload::text not like '%' || (select token from t_mail_appr) || '%'
      and o.payload::text not like '%@%'
      and p.variables ->> 'token' = (select token from t_mail_appr)
      and p.invite_link_id = (select invite_link_id from t_mail_appr)
    from messaging.outbox o
    join identity.pending_emails p on p.id = (o.payload ->> 'pending_email_id')::uuid
   where o.event_type = 'email.signup_approved'
     and p.recipient = 'ack@email-test.example'),
  'the invite token is not in the outbox payload');
select tests.ok(
  (select o.payload::text not ilike '%synthetic-reject-reason-zz%'
      and p.variables ->> 'reason' = 'synthetic-reject-reason-zz'
    from messaging.outbox o
    join identity.pending_emails p on p.id = (o.payload ->> 'pending_email_id')::uuid
   where o.event_type = 'email.signup_rejected' and p.recipient = 'reject@email-test.example'),
  'the rejection reason is not in the outbox payload');

-- --------------------------------------------------------------- staff invite ----
select tests.authenticate_as('ack@email-test.example');
select identity.claim_invite_link((select token from t_mail_appr));
create temporary table t_mail_staff on commit drop as
  select * from identity.create_member_invite_link((select tenant_id from t_mail_appr), 'Nurse@email-test.example', 'nurse', null);
grant select on t_mail_staff to public;

select tests.as_superuser();
select tests.ok(
  (select count(*) = 1 from identity.pending_emails p, t_mail_staff s
    where p.invite_link_id = s.id and p.template_key = 'invite_link' and p.redacted_on is null
      and p.variables ->> 'token' = s.token),
  'a staff invite queues an email with the new token');

select tests.authenticate_as('ack@email-test.example');
select identity.revoke_invite_link((select tenant_id from t_mail_appr), (select id from t_mail_staff));
select tests.as_superuser();
select tests.ok(
  (select p.redacted_on is not null and p.recipient = 'redacted@invalid.local' and p.variables = '{}'::jsonb
     from identity.pending_emails p, t_mail_staff s where p.invite_link_id = s.id),
  'revoking a link redacts the unsent email');

-- --------------------------------------------------------------- re-send ----
select tests.authenticate_as('op-mail@medicore.example');
create temporary table t_mail_reissue on commit drop as
  select * from identity.platform_reissue_admin_invite((select tenant_id from t_mail_appr), 'ack@email-test.example');
grant select on t_mail_reissue to public;
select tests.as_superuser();
select tests.ok(
  (select count(*) = 1 from identity.pending_emails p, t_mail_reissue s
    where p.invite_link_id = s.invite_link_id and p.template_key = 'invite_link' and p.redacted_on is null),
  're-issuing an admin invite queues a new email');

-- ---------------------------------------------------- who may deliver ----
create temporary table t_mail_event on commit drop as
  select o.id, o.event_id, o.tenant_id
    from messaging.outbox o
    join identity.pending_emails p on p.id = (o.payload ->> 'pending_email_id')::uuid
   where o.event_type = 'email.signup_rejected' and p.recipient = 'reject@email-test.example';
grant select on t_mail_event to public;

-- Per-aggregate order: earlier unsent emails on this signup stay ahead of the rejection.
update messaging.outbox earlier
   set status = 'done', processed_on = now(), processed_at = now()
  from t_mail_event ev
  join messaging.outbox target on target.id = ev.id
 where earlier.aggregate_type = 'email_message'
   and earlier.tenant_id = target.tenant_id
   and earlier.aggregate_id = target.aggregate_id
   and earlier.id < target.id
   and earlier.status in ('pending', 'processing');

set local session authorization hms_scheduling_login;
set local role hms_dispatcher;
select tests.ok(
  (select count(*) from messaging.claim_outbox('sched-no-mail', 50) c where c.aggregate_type = 'email_message') = 0,
  'the scheduling dispatcher does not claim email events');
reset role;
reset session authorization;

set local session authorization hms_api_login;
select tests.throws_ok($$set local role hms_mailer$$, '42501', 'B1: the legacy login cannot become the mailer');
reset session authorization;

set local session authorization hms_patients_login;
select tests.throws_ok($$set local role hms_mailer$$, '42501', 'the patients login cannot become the mailer');
reset session authorization;

set local session authorization hms_identity_login;
set local role hms_mailer;
select tests.ok(messaging.caller_sources() = array['identity'], 'the identity login consumes the identity source');
select tests.ok(
  (select count(*) from messaging.claim_email_outbox('mail-1', 50) c where c.event_id = (select event_id from t_mail_event)) = 1,
  'the identity mailer claims the rejection email');
select tests.ok(messaging.record_email_sent((select event_id from t_mail_event), (select tenant_id from t_mail_event)),
  'the first receipt for an event_id is recorded');
select tests.ok(not messaging.record_email_sent((select event_id from t_mail_event), (select tenant_id from t_mail_event)),
  'recording the same event_id again is a no-op');
select tests.ok(messaging.email_already_sent((select event_id from t_mail_event)),
  'email_already_sent follows the receipt');
select messaging.complete_outbox((select id from t_mail_event), 'mail-1');
reset role;
reset session authorization;

select tests.as_superuser();
select tests.ok(
  (select status = 'done' from messaging.outbox where event_id = (select event_id from t_mail_event))
  and (select count(*) = 1 from messaging.email_send_receipts where event_id = (select event_id from t_mail_event)),
  'the event is done and has exactly one send receipt');

rollback;
