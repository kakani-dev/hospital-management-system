-- #59: appointment reminders: settings, opt-outs, and the due-reminder sweep. Relative dates; Zz-QA data; rolls back.
begin;

select tests.ok(
  has_table_privilege('hms_svc_scheduling', 'appointment.reminder_settings', 'update')
  and has_table_privilege('hms_svc_scheduling', 'appointment.reminder_opt_outs', 'insert')
  and has_table_privilege('hms_svc_scheduling', 'appointment.appointment_reminders', 'select')
  and not has_table_privilege('hms_svc_scheduling', 'appointment.appointment_reminders', 'update')
  and not has_table_privilege('authenticated', 'appointment.reminder_settings', 'select')
  and has_function_privilege('hms_svc_scheduling', 'appointment.claim_due_reminders(integer, interval)', 'execute')
  and not has_function_privilege('authenticated', 'appointment.claim_due_reminders(integer, interval)', 'execute'),
  'scheduling service owns reminders; the log is written only through the sweep functions');

select tests.throws_ok($$insert into appointment.reminder_settings (tenant_id, lead_hours, created_by, updated_by)
  values ('11111111-1111-4111-8111-111111111111', 100, '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001')$$,
  '23514', 'lead time is 1-72 hours');
select tests.throws_ok($$insert into appointment.reminder_settings (tenant_id, lead_hours, same_day_hours, created_by, updated_by)
  values ('11111111-1111-4111-8111-111111111111', 4, 6, '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001')$$,
  '23514', 'the same-day reminder must be closer than the first one');

-- No settings row = reminders off: nothing is planned.
update appointment.appointments set starts_at = now() + interval '20 hours', ends_at = now() + interval '20 hours 20 minutes'
 where id = 'e1111111-0000-4000-8000-000000000001';
set local session_replication_role = replica;
update appointment.appointments set created_on = now() - interval '2 days' where id = 'e1111111-0000-4000-8000-000000000001';
set local session_replication_role = origin;
update patient.patients set email = 'zz-qa.reminder@example.test' where id = 'aa000000-0000-4000-8000-000000000001';
select tests.ok((select count(*) = 0 from appointment.claim_due_reminders(50)), 'reminders are off until a tenant enables them');

insert into appointment.reminder_settings (tenant_id, enabled, quiet_start, quiet_end, created_by, updated_by)
values ('11111111-1111-4111-8111-111111111111', true, '00:00', '00:00', '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001');

create temp table claimed on commit drop as select * from appointment.claim_due_reminders(50);
select tests.ok((select count(*) = 1 and bool_and(kind = 'lead' and channel = 'email' and recipient = 'zz-qa.reminder@example.test') from claimed
                  where appointment_id = 'e1111111-0000-4000-8000-000000000001'),
  'a booked visit inside the lead window gets one email reminder');
select tests.ok((select count(*) = 0 from appointment.claim_due_reminders(50) where appointment_id = 'e1111111-0000-4000-8000-000000000001'),
  'a leased reminder is not claimed twice (duplicate sweeps / replicas)');
select appointment.complete_reminder((select reminder_id from claimed limit 1), 'sent', 'ok', 'zz***@example.test');
select tests.ok((select status = 'sent' and recipient_masked like 'zz***%' from appointment.appointment_reminders where appointment_id = 'e1111111-0000-4000-8000-000000000001'),
  'completion records the masked recipient only');

-- Reschedule: the new time gets a fresh reminder.
update appointment.appointments set starts_at = now() + interval '22 hours', ends_at = now() + interval '22 hours 20 minutes'
 where id = 'e1111111-0000-4000-8000-000000000001';
select tests.ok((select count(*) = 1 from appointment.claim_due_reminders(50) where appointment_id = 'e1111111-0000-4000-8000-000000000001'),
  'a rescheduled visit is reminded again for its new time');

-- Cancelled: pending rows are dropped.
update appointment.appointment_reminders set status = 'queued' where appointment_id = 'e1111111-0000-4000-8000-000000000001' and status = 'sending';
update appointment.appointments set status = 'cancelled' where id = 'e1111111-0000-4000-8000-000000000001';
select tests.ok((select count(*) = 0 from appointment.claim_due_reminders(50) where appointment_id = 'e1111111-0000-4000-8000-000000000001'), 'sweep claims nothing for it');
select tests.ok((select count(*) >= 1 from appointment.appointment_reminders where appointment_id = 'e1111111-0000-4000-8000-000000000001'
        and status = 'skipped' and detail = 'appointment changed before sending'),
  'a cancelled visit is not reminded');

-- Opt-out (DND) and walk-in. (Fixture reset bypasses the transition trigger.)
set local session_replication_role = replica;
update appointment.appointments set status = 'booked', starts_at = now() + interval '30 hours', ends_at = now() + interval '30 hours 20 minutes'
 where id = 'e1111111-0000-4000-8000-000000000001';
set local session_replication_role = origin;
update appointment.reminder_settings set lead_hours = 48 where tenant_id = '11111111-1111-4111-8111-111111111111';
insert into appointment.reminder_opt_outs (tenant_id, patient_id, reason, created_by, updated_by)
values ('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000001', 'Zz-QA asked at desk', '0d000000-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000001');
select tests.ok((select count(*) = 0 from appointment.claim_due_reminders(50) where appointment_id = 'e1111111-0000-4000-8000-000000000001'), 'sweep claims nothing for it');
select tests.ok(exists (select 1 from appointment.appointment_reminders where appointment_id = 'e1111111-0000-4000-8000-000000000001'
               and status = 'skipped' and detail = 'patient opted out of reminders'),
  'an opted-out patient is skipped with a reason');

delete from appointment.reminder_opt_outs where patient_id = 'aa000000-0000-4000-8000-000000000001';
set local session_replication_role = replica;
update appointment.appointments set starts_at = now() + interval '1 hour', ends_at = now() + interval '1 hour 20 minutes', created_on = now() - interval '10 minutes'
 where id = 'e1111111-0000-4000-8000-000000000001';
set local session_replication_role = origin;
select tests.ok((select count(*) = 0 from appointment.claim_due_reminders(50) where appointment_id = 'e1111111-0000-4000-8000-000000000001'),
  'a walk-in booked with less than the minimum notice gets no reminder');

-- Missing contact.
set local session_replication_role = replica;
update appointment.appointments set created_on = now() - interval '2 days' where id = 'e1111111-0000-4000-8000-000000000001';
set local session_replication_role = origin;
update patient.patients set email = null where id = 'aa000000-0000-4000-8000-000000000001';
select tests.ok((select count(*) = 0 from appointment.claim_due_reminders(50) where appointment_id = 'e1111111-0000-4000-8000-000000000001'), 'sweep claims nothing for it');
select tests.ok(exists (select 1 from appointment.appointment_reminders where appointment_id = 'e1111111-0000-4000-8000-000000000001'
               and channel = 'none' and status = 'skipped'),
  'no email or WhatsApp on file is recorded as skipped, not an error');

-- Quiet hours (whole day quiet) hold everything back.
update patient.patients set email = 'zz-qa.reminder@example.test' where id = 'aa000000-0000-4000-8000-000000000001';
update appointment.appointments set starts_at = now() + interval '10 hours', ends_at = now() + interval '10 hours 20 minutes' where id = 'e1111111-0000-4000-8000-000000000001';
update appointment.reminder_settings set quiet_start = '00:00', quiet_end = '23:59:59' where tenant_id = '11111111-1111-4111-8111-111111111111';
select tests.ok((select count(*) = 0 from appointment.claim_due_reminders(50) where appointment_id = 'e1111111-0000-4000-8000-000000000001')
  or ((now() at time zone 'Asia/Kolkata')::time >= '23:59:59'),
  'nothing is sent during branch-local quiet hours');

select tests.throws_ok($$select appointment.complete_reminder(gen_random_uuid(), 'queued', null, null)$$, '22023', 'completion accepts only final statuses');

rollback;
