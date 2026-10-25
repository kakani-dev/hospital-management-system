-- Outbox dispatcher: per-aggregate order, receipts, stale drain, and source scope.
begin;

select tests.ok(
  (select count(*) = 5 from information_schema.columns
    where table_schema = 'messaging' and table_name = 'dispatch_receipt'
      and column_name in ('created_on', 'created_by', 'updated_on', 'updated_by', 'is_deleted')
      and is_nullable = 'NO'),
  'dispatch_receipt has the five audit columns');
select tests.ok(
  (select relrowsecurity from pg_class where oid = 'messaging.dispatch_receipt'::regclass)
  and has_function_privilege('hms_dispatcher', 'messaging.note_outbox_dispatched(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'messaging.note_outbox_dispatched(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'messaging.skip_stale_outbox(boolean)', 'execute'),
  'receipts are RLS-protected and only the dispatcher may note or skip');

select tests.ok(
  messaging.outbox_row_is_stale('appointment', now() - interval '3 days')
  and not messaging.outbox_row_is_stale('appointment', now() - interval '1 day')
  and messaging.outbox_row_is_stale('queue_entry', now() - interval '3 days')
  and messaging.outbox_row_is_stale('tenant', now() - interval '8 days')
  and not messaging.outbox_row_is_stale('tenant', now() - interval '6 days')
  and messaging.outbox_row_is_stale('billing', now() - interval '8 days')
  and not messaging.outbox_row_is_stale('patient', now() - interval '6 days')
  and not messaging.outbox_row_is_stale('email_message', now() - interval '30 days'),
  'appointment and queue go stale after 2 days, other domain events after 7, email never');

select tests.as_superuser();
update messaging.outbox set status = 'done' where status in ('pending', 'processing');

-- ---------- one head per aggregate ----------
insert into messaging.outbox (tenant_id, aggregate_type, aggregate_id, event_type, payload)
values
  ('11111111-1111-4111-8111-111111111111', 'appointment', 'e40e40e4-0000-4000-8000-000000000001', 'test.head', '{}'),
  ('11111111-1111-4111-8111-111111111111', 'appointment', 'e40e40e4-0000-4000-8000-000000000001', 'test.tail', '{}'),
  ('11111111-1111-4111-8111-111111111111', 'queue_entry', 'e40e40e4-0000-4000-8000-000000000002', 'test.other', '{}');

set local role hms_dispatcher;
create temporary table t_heads on commit drop as
  select id, event_type from messaging.claim_outbox('order-1', 10);
select tests.ok(
  (select array_agg(event_type order by id) from t_heads) = array['test.head', 'test.other'],
  'a batch takes the oldest head of each aggregate and leaves the tail');
select tests.ok((select count(*) from messaging.claim_outbox('order-2', 10) c where c.event_type = 'test.tail') = 0,
  'the tail stays behind the leased head');
select messaging.complete_outbox((select id from t_heads where event_type = 'test.head'), 'order-1');
select tests.ok(
  (select count(*) = 1 and min(event_type) = 'test.tail' from messaging.claim_outbox('order-3', 10) c where c.event_type = 'test.tail'),
  'the tail is claimed once the head is done');
reset role;

-- ---------- email stays with the mailer, in aggregate order ----------
insert into messaging.outbox (tenant_id, aggregate_type, aggregate_id, event_type, payload)
values
  ('11111111-1111-4111-8111-111111111111', 'email_message', 'e40e40e4-0000-4000-8000-000000000003', 'test.mail.1',
   jsonb_build_object('pending_email_id', 'e40e40e4-0000-4000-8000-000000000011', 'template_key', 'signup_received')),
  ('11111111-1111-4111-8111-111111111111', 'email_message', 'e40e40e4-0000-4000-8000-000000000003', 'test.mail.2',
   jsonb_build_object('pending_email_id', 'e40e40e4-0000-4000-8000-000000000012', 'template_key', 'signup_received'));

set local session authorization hms_identity_login;
set local role hms_dispatcher;
select tests.ok(
  (select count(*) from messaging.claim_outbox('id-no-mail', 20) c where c.aggregate_type = 'email_message') = 0,
  'the identity domain dispatcher does not take email rows');
reset role;
set local role hms_mailer;
create temporary table t_mail on commit drop as
  select id, event_type from messaging.claim_email_outbox('mail-order', 10);
select tests.ok(
  (select count(*) = 1 and min(event_type) = 'test.mail.1' from t_mail),
  'the mailer claims only the oldest email on an aggregate');
reset role;
reset session authorization;

-- ---------- receipts: tenant comes from the row, clients cannot write ----------
reset role;
select tests.as_superuser();
insert into messaging.outbox (tenant_id, aggregate_type, aggregate_id, event_type, payload)
values ('11111111-1111-4111-8111-111111111111', 'billing', 'e40e40e4-0000-4000-8000-000000000004', 'test.receipt', '{}');
create temporary table t_receipt_event on commit drop as
  select event_id from messaging.outbox where event_type = 'test.receipt';
grant select on t_receipt_event to hms_dispatcher, authenticated;

set local role hms_dispatcher;
select tests.throws_ok(
  format('select messaging.note_outbox_dispatched(%L, %L)',
    (select event_id from t_receipt_event), '22222222-2222-4222-8222-222222222222'),
  '42501', 'a note with the wrong tenant is refused');
select messaging.note_outbox_dispatched(
  (select event_id from t_receipt_event), '11111111-1111-4111-8111-111111111111');
select messaging.note_outbox_dispatched(
  (select event_id from t_receipt_event), '11111111-1111-4111-8111-111111111111');
select tests.ok(
  messaging.outbox_was_dispatched((select event_id from t_receipt_event)),
  'the receipt is visible to the dispatcher that wrote it');
reset role;
select tests.ok(
  (select count(*) = 1 and bool_and(not is_deleted) and bool_and(created_by is not null)
        and bool_and(created_on is not null) and bool_and(source_service = 'billing')
   from messaging.dispatch_receipt
   where event_id = (select event_id from t_receipt_event)),
  'the first note is kept and a repeat does not add a second receipt');

select tests.authenticate_as('admin@alpha.example');
select tests.ok(
  (select count(*) from messaging.dispatch_receipt
    where event_id = (select event_id from t_receipt_event)) = 1,
  'a tenant admin with members.manage can read the receipt');
select tests.throws_ok(
  $$insert into messaging.dispatch_receipt (event_id, tenant_id, source_service)
    values ('e40e40e4-0000-4000-8000-000000000099', '11111111-1111-4111-8111-111111111111', 'billing')$$,
  '42501', 'authenticated cannot insert a dispatch receipt');
select tests.authenticate_as('reception@alpha.example');
select tests.ok(
  (select count(*) from messaging.dispatch_receipt
    where event_id = (select event_id from t_receipt_event)) = 0,
  'a receptionist cannot read the receipt');

-- ---------- stale drain is a count until apply ----------
select tests.as_superuser();
update messaging.outbox set status = 'done' where status in ('pending', 'processing');
insert into messaging.outbox (tenant_id, aggregate_type, aggregate_id, event_type, payload, occurred_at)
values
  ('11111111-1111-4111-8111-111111111111', 'appointment', 'e40e40e4-0000-4000-8000-000000000021', 'test.stale_appt', '{}', now() - interval '3 days'),
  ('11111111-1111-4111-8111-111111111111', 'appointment', 'e40e40e4-0000-4000-8000-000000000022', 'test.fresh_appt', '{}', now() - interval '1 day'),
  ('11111111-1111-4111-8111-111111111111', 'tenant', 'e40e40e4-0000-4000-8000-000000000023', 'test.stale_tenant', '{}', now() - interval '8 days'),
  ('11111111-1111-4111-8111-111111111111', 'tenant', 'e40e40e4-0000-4000-8000-000000000024', 'test.fresh_tenant', '{}', now() - interval '6 days'),
  ('11111111-1111-4111-8111-111111111111', 'email_message', 'e40e40e4-0000-4000-8000-000000000025', 'test.old_mail',
   jsonb_build_object('pending_email_id', 'e40e40e4-0000-4000-8000-000000000026', 'template_key', 'signup_received'),
   now() - interval '30 days');

set local role hms_dispatcher;
create temporary table t_skip_dry on commit drop as select messaging.skip_stale_outbox(false) as result;
reset role;
select tests.ok(
  (select (result ->> 'stale')::bigint = 2 and (result ->> 'skipped')::bigint = 0 from t_skip_dry)
  and (select count(*) from messaging.outbox where event_type in ('test.stale_appt', 'test.stale_tenant') and status = 'pending') = 2,
  'a dry run counts stale rows and leaves them pending');
set local role hms_dispatcher;
create temporary table t_skip_apply on commit drop as select messaging.skip_stale_outbox(true) as result;
reset role;
select tests.ok(
  (select (result ->> 'skipped')::bigint = 2 from t_skip_apply)
  and (select count(*) = 2 and bool_and(status = 'dead' and attempts = 0 and processed_on is not null
        and last_error = 'skipped: stale before dispatcher enablement')
       from messaging.outbox where event_type in ('test.stale_appt', 'test.stale_tenant'))
  and (select count(*) = 2 and bool_and(status = 'pending' and attempts = 0)
       from messaging.outbox where event_type in ('test.fresh_appt', 'test.fresh_tenant'))
  and (select status = 'pending' and attempts = 0 from messaging.outbox where event_type = 'test.old_mail'),
  'apply dead-letters only the stale domain rows and never an email');
set local role hms_dispatcher;
select tests.ok(
  (messaging.outbox_backlog() ->> 'stalePending')::bigint = 0
  and (messaging.outbox_backlog() ->> 'pending')::bigint = 2,
  'the backlog excludes email and no longer counts the skipped rows as stale');

rollback;
