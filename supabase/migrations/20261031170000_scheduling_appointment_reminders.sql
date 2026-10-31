-- cross-schema: approved (audit.* triggers and identity.current_tenant_ids() in RLS; new published read patient.reminder_contact_v1 for the scheduling service; the sweep uses only v1 functions across schemas)
-- #59: appointment reminders (email via MailKit, optional WhatsApp via WAHA), scheduled by a Hangfire sweep
-- in the scheduling service. The database decides WHO is due; the service decides whether it may actually
-- send (Reminders:Mode, test-recipient allowlist). Everything is per-tenant settings; nothing is hard-coded.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ------------------------------------------------------------------ settings ----
create table appointment.reminder_settings (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references identity.tenants (id) on delete restrict,
  enabled                boolean not null default false,
  lead_hours             smallint not null default 24,
  same_day_hours         smallint not null default 2,
  min_notice_minutes     smallint not null default 120,
  email_enabled          boolean not null default true,
  whatsapp_enabled       boolean not null default false,
  quiet_start            time not null default '21:00',
  quiet_end              time not null default '08:00',
  created_on             timestamptz not null default now(),
  created_by             uuid not null,
  updated_on             timestamptz not null default now(),
  updated_by             uuid not null,
  is_deleted             boolean not null default false,
  constraint reminder_settings_tenant_key unique (tenant_id),
  constraint reminder_settings_lead check (lead_hours between 1 and 72),
  constraint reminder_settings_same_day check (same_day_hours between 0 and 12 and same_day_hours < lead_hours),
  constraint reminder_settings_notice check (min_notice_minutes between 0 and 1440)
);
comment on table appointment.reminder_settings is
  '#59: one row per tenant; no row = reminders off. lead_hours = first reminder; same_day_hours = second (0 = none); '
  'appointments booked with less than min_notice_minutes notice (walk-ins) get none; nothing is sent in branch-local quiet hours.';

-- ---------------------------------------------------------------- opt-outs ----
create table appointment.reminder_opt_outs (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references identity.tenants (id) on delete restrict,
  patient_id  uuid not null,
  reason      text,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  constraint reminder_opt_outs_reason_len check (reason is null or char_length(reason) <= 200)
);
create unique index reminder_opt_outs_key on appointment.reminder_opt_outs (tenant_id, patient_id);
comment on table appointment.reminder_opt_outs is '#59: patient asked not to be reminded (DND). Deleting the row (audited) = opted back in.';

-- -------------------------------------------------------------- reminder log ----
create table appointment.appointment_reminders (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references identity.tenants (id) on delete restrict,
  appointment_id   uuid not null,
  kind             text not null,
  channel          text not null,
  scheduled_start  timestamptz not null,
  status           text not null default 'queued',
  detail           text,
  recipient_masked text,
  attempts         smallint not null default 0,
  claimed_until    timestamptz,
  sent_at          timestamptz,
  created_on       timestamptz not null default now(),
  created_by       uuid not null default '00000000-0000-4000-8000-00000000005e',
  updated_on       timestamptz not null default now(),
  updated_by       uuid not null default '00000000-0000-4000-8000-00000000005e',
  is_deleted       boolean not null default false,
  constraint appointment_reminders_appointment_fk foreign key (tenant_id, appointment_id)
    references appointment.appointments (tenant_id, id) on delete cascade,
  constraint appointment_reminders_kind check (kind in ('lead', 'same_day')),
  constraint appointment_reminders_channel check (channel in ('email', 'whatsapp', 'none')),
  constraint appointment_reminders_status check (status in ('queued', 'sending', 'sent', 'skipped', 'failed')),
  -- a reschedule changes scheduled_start, so the new time gets its own reminders
  constraint appointment_reminders_once unique (appointment_id, kind, channel, scheduled_start)
);
create index appointment_reminders_due on appointment.appointment_reminders (status, claimed_until) where status in ('queued', 'sending', 'failed');
create index appointment_reminders_tenant_appt on appointment.appointment_reminders (tenant_id, appointment_id);
comment on table appointment.appointment_reminders is
  '#59: one row per (appointment, kind, channel, start time). recipient_masked only; the full address is never stored here.';

create trigger reminder_settings_audit_columns before insert or update on appointment.reminder_settings
  for each row execute function audit.stamp_audit_columns();
create trigger reminder_settings_tenant_immutable before update on appointment.reminder_settings
  for each row execute function audit.prevent_tenant_change();
create trigger reminder_settings_audit_log after insert or update or delete on appointment.reminder_settings
  for each row execute function audit.log_row_change();
create trigger reminder_opt_outs_audit_columns before insert or update on appointment.reminder_opt_outs
  for each row execute function audit.stamp_audit_columns();
create trigger reminder_opt_outs_tenant_immutable before update on appointment.reminder_opt_outs
  for each row execute function audit.prevent_tenant_change();
create trigger reminder_opt_outs_audit_log after insert or update or delete on appointment.reminder_opt_outs
  for each row execute function audit.log_row_change();
create trigger appointment_reminders_audit_columns before insert or update on appointment.appointment_reminders
  for each row execute function audit.stamp_audit_columns();
create trigger appointment_reminders_tenant_immutable before update on appointment.appointment_reminders
  for each row execute function audit.prevent_tenant_change();
create trigger appointment_reminders_audit_log after insert or update or delete on appointment.appointment_reminders
  for each row execute function audit.log_row_change();

alter table appointment.reminder_settings enable row level security;
alter table appointment.reminder_opt_outs enable row level security;
alter table appointment.appointment_reminders enable row level security;
revoke all on appointment.reminder_settings, appointment.reminder_opt_outs, appointment.appointment_reminders from anon, authenticated, public;
grant select, insert, update on appointment.reminder_settings to hms_svc_scheduling;
grant select, insert, delete on appointment.reminder_opt_outs to hms_svc_scheduling;
grant select on appointment.appointment_reminders to hms_svc_scheduling;
grant all on appointment.reminder_settings, appointment.reminder_opt_outs, appointment.appointment_reminders to service_role;
create policy reminder_settings_tenant on appointment.reminder_settings for all to hms_svc_scheduling
  using (tenant_id in (select identity.current_tenant_ids()))
  with check (tenant_id in (select identity.current_tenant_ids()));
create policy reminder_opt_outs_tenant on appointment.reminder_opt_outs for all to hms_svc_scheduling
  using (tenant_id in (select identity.current_tenant_ids()))
  with check (tenant_id in (select identity.current_tenant_ids()));
create policy appointment_reminders_tenant on appointment.appointment_reminders for select to hms_svc_scheduling
  using (tenant_id in (select identity.current_tenant_ids()));

-- ------------------------------------------------- published patient contact read ----
-- Published by patients for scheduling's reminder sweep: first name, email and WhatsApp number only.
-- cross-schema: approved (published read for appointment.claim_due_reminders; tenant-scoped, minimal columns)
create or replace function patient.reminder_contact_v1(p_tenant_id uuid, p_patient_ids uuid[])
returns table (patient_id uuid, first_name text, email text, whatsapp_e164 text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.first_name, nullif(btrim(p.email), ''),
         (select ph.phone_e164 from patient.patient_phones ph
           where ph.patient_id = p.id and ph.is_whatsapp and not ph.is_deleted
           order by ph.is_primary desc limit 1)
    from patient.patients p
   where p.tenant_id = p_tenant_id and p.id = any (p_patient_ids) and not p.is_deleted
$$;
comment on function patient.reminder_contact_v1(uuid, uuid[]) is
  'v1 (published by patients, #59): reminder contact for live patients of one tenant. Service-only.';
revoke all on function patient.reminder_contact_v1(uuid, uuid[]) from public, anon, authenticated;
grant execute on function patient.reminder_contact_v1(uuid, uuid[]) to hms_svc_scheduling, service_role;

-- ------------------------------------------------------------------- sweep ----
-- Cross-tenant by design (background job, no tenant session). Plans due rows, records skips
-- (opt-out, no contact), then leases up to p_limit sendable rows. Returns contact details to the
-- caller only for leased rows; they are never persisted unmasked.
create or replace function appointment.claim_due_reminders(p_limit integer default 50, p_lease interval default interval '5 minutes')
returns table (
  reminder_id uuid, tenant_id uuid, appointment_id uuid, kind text, channel text, recipient text,
  patient_first_name text, practitioner_label text, branch_name text, starts_at timestamptz, time_zone text, attempts smallint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  with cand as (
    select a.id, a.tenant_id, a.patient_id, a.starts_at, a.branch_id, s.email_enabled, s.whatsapp_enabled,
           identity.branch_time_zone_v1(a.branch_id) as tz,
           case
             when a.starts_at <= now() + make_interval(hours => s.same_day_hours) then 'same_day'
             else 'lead'
           end as kind,
           s.quiet_start, s.quiet_end, s.same_day_hours
      from appointment.appointments a
      join appointment.reminder_settings s on s.tenant_id = a.tenant_id and s.enabled and not s.is_deleted
     where a.status = 'booked' and not a.is_deleted
       and a.starts_at > now()
       and a.starts_at <= now() + make_interval(hours => s.lead_hours)
       and a.starts_at - a.created_on >= make_interval(mins => s.min_notice_minutes)
  ), due as (
    select c.* from cand c
     -- same_day: skip when this start time's lead reminder was itself created within 2x same_day_hours
     -- of the visit (booked late, so one reminder is enough)
     where not (c.kind = 'same_day' and exists (
             select 1 from appointment.appointment_reminders r
              where r.appointment_id = c.id and r.scheduled_start = c.starts_at and r.kind = 'lead'
                and r.created_on > c.starts_at - make_interval(hours => c.same_day_hours * 2)))
       -- quiet hours, branch-local (window may wrap midnight)
       and not (case when c.quiet_start = c.quiet_end then false
                     when c.quiet_start < c.quiet_end then (now() at time zone c.tz)::time >= c.quiet_start and (now() at time zone c.tz)::time < c.quiet_end
                     else (now() at time zone c.tz)::time >= c.quiet_start or (now() at time zone c.tz)::time < c.quiet_end end)
  ), contact as (
    select d.*, pc.email, pc.whatsapp_e164 as wa,
           exists (select 1 from appointment.reminder_opt_outs o
                    where o.tenant_id = d.tenant_id and o.patient_id = d.patient_id) as opted_out
      from due d
      cross join lateral patient.reminder_contact_v1(d.tenant_id, array[d.patient_id]) pc
  ), planned as (
    select c.tenant_id, c.id as appointment_id, c.kind, ch.channel, c.starts_at,
           case when c.opted_out then 'skipped' when ch.channel = 'none' then 'skipped' else 'queued' end as status,
           case when c.opted_out then 'patient opted out of reminders'
                when ch.channel = 'none' then 'no email or WhatsApp number on file' end as detail
      from contact c
      cross join lateral (
        select 'email' as channel where c.email_enabled and nullif(btrim(c.email), '') is not null
        union all
        select 'whatsapp' where c.whatsapp_enabled and c.wa is not null
        union all
        select 'none' where not ((c.email_enabled and nullif(btrim(c.email), '') is not null) or (c.whatsapp_enabled and c.wa is not null))
      ) ch
  )
  insert into appointment.appointment_reminders (tenant_id, appointment_id, kind, channel, scheduled_start, status, detail)
  select tenant_id, appointment_id, kind, channel, starts_at, status, detail from planned
  on conflict on constraint appointment_reminders_once do nothing;

  -- appointments cancelled / rescheduled / no longer booked: drop their pending rows
  update appointment.appointment_reminders r
     set status = 'skipped', detail = 'appointment changed before sending', updated_on = now(), claimed_until = null
    from appointment.appointments a
   where a.id = r.appointment_id and r.status in ('queued', 'failed')
     and (a.status <> 'booked' or a.is_deleted or a.starts_at <> r.scheduled_start or a.starts_at <= now());

  return query
  with picked as (
    select r.id from appointment.appointment_reminders r
     where (r.status = 'queued'
            or (r.status = 'failed' and r.attempts < 3 and r.updated_on < now() - interval '10 minutes')
            or (r.status = 'sending' and r.claimed_until < now()))
     order by r.scheduled_start
     limit greatest(1, least(p_limit, 500))
     for update skip locked
  ), leased as (
    update appointment.appointment_reminders r
       set status = 'sending', attempts = r.attempts + 1, claimed_until = now() + p_lease, updated_on = now()
      from picked where r.id = picked.id
    returning r.*
  )
  select l.id, l.tenant_id, l.appointment_id, l.kind, l.channel,
         case l.channel when 'email' then pc.email when 'whatsapp' then pc.whatsapp_e164 end,
         pc.first_name, appointment.practitioner_label_v1(a.tenant_id, a.practitioner_id),
         (select h.name from identity.branch_bill_header_v1(a.tenant_id, a.branch_id) h limit 1),
         a.starts_at, identity.branch_time_zone_v1(a.branch_id), l.attempts
    from leased l
    join appointment.appointments a on a.id = l.appointment_id
    left join lateral patient.reminder_contact_v1(a.tenant_id, array[a.patient_id]) pc on true;
end;
$$;

create or replace function appointment.complete_reminder(p_id uuid, p_status text, p_detail text, p_recipient_masked text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_status not in ('sent', 'skipped', 'failed') then
    raise exception 'invalid reminder status %', p_status using errcode = '22023';
  end if;
  update appointment.appointment_reminders
     set status = p_status, detail = left(p_detail, 300), recipient_masked = left(p_recipient_masked, 80),
         sent_at = case when p_status = 'sent' then now() end, claimed_until = null, updated_on = now()
   where id = p_id and status = 'sending';
end;
$$;

revoke all on function appointment.claim_due_reminders(integer, interval) from public, anon, authenticated;
revoke all on function appointment.complete_reminder(uuid, text, text, text) from public, anon, authenticated;
grant execute on function appointment.claim_due_reminders(integer, interval) to hms_svc_scheduling, service_role;
grant execute on function appointment.complete_reminder(uuid, text, text, text) to hms_svc_scheduling, service_role;
