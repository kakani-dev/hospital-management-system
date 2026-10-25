-- scripts/demo/remove-demo-data.sql
-- Removes ONLY the synthetic data written by seed-demo-data.sql / create-demo-logins.py from the
-- tenant 'MediCore Demo Hospital' (77519cf6-1d9b-4954-8bc6-f29bbb734786). Nothing else is touched.
--
-- What counts as seeded (tags):
--   * patients whose email ends with @demo-seed.example.com, and everything hanging off them
--     (appointments, queue entries, billing accounts, bills, lines, discounts, payments, refunds, tenders, allocations)
--   * appointments whose reason starts with '[demo-seed]'
--   * branches / practitioners / service items listed in identity.tenants.settings->'demo_seed'
--   * staff logins whose email ends with @demo-seed.example.com (memberships, profiles, auth users)
--
-- Runs as one transaction (the DO block). User triggers (audit stamping, outbox, immutability guards) are
-- disabled for the duration so the cleanup does not emit fake domain events; FK checks stay on.
--
-- Dry run: run  `select set_config('demo.dry_run', 'on', false);`  in the same session first; the block then
-- reports what it would delete and rolls back.
do $$
declare
  T constant uuid := '77519cf6-1d9b-4954-8bc6-f29bbb734786';
  v_manifest jsonb;
  v_counts jsonb := '{}'::jsonb;
  n bigint;
  r record;
begin
  select settings -> 'demo_seed' into v_manifest from identity.tenants where id = T;

  create temp table rm_patient on commit drop as
    select id from patient.patients where tenant_id = T and email like '%@demo-seed.example.com';
  create temp table rm_branch on commit drop as
    select (jsonb_array_elements_text(coalesce(v_manifest -> 'branches', '[]')))::uuid id;
  create temp table rm_prac on commit drop as
    select (jsonb_array_elements_text(coalesce(v_manifest -> 'practitioners', '[]')))::uuid id;
  create temp table rm_item on commit drop as
    select (jsonb_array_elements_text(coalesce(v_manifest -> 'service_items', '[]')))::uuid id;
  create temp table rm_user on commit drop as
    select id from auth.users where email like '%@demo-seed.example.com';
  create temp table rm_appt on commit drop as
    select id from appointment.appointments
     where tenant_id = T and (patient_id in (select id from rm_patient) or reason like '[demo-seed]%'
                              or practitioner_id in (select id from rm_prac) or branch_id in (select id from rm_branch));
  create temp table rm_account on commit drop as
    select id from billing.billing_account
     where tenant_id = T and (patient_id in (select id from rm_patient) or branch_id in (select id from rm_branch)
                              or source_ref_id in (select id from rm_appt));
  create temp table rm_bill on commit drop as
    select id from billing.bill where tenant_id = T and account_id in (select id from rm_account);
  create temp table rm_payment on commit drop as
    select id from billing.payment where tenant_id = T and account_id in (select id from rm_account);
  create temp table rm_session on commit drop as
    select s.id from billing.counter_session s join billing.counter c on c.id = s.counter_id
     where s.tenant_id = T and c.branch_id in (select id from rm_branch);
  create temp table rm_approval on commit drop as
    select approval_id id from billing.discount where bill_id in (select id from rm_bill) and approval_id is not null
    union select approval_id from billing.payment where id in (select id from rm_payment) and approval_id is not null
    union select variance_approval_id from billing.counter_close where counter_session_id in (select id from rm_session) and variance_approval_id is not null
    union select id from billing.approval_request where tenant_id = T
            and subject_id in (select id from rm_bill union select id from rm_payment);

  for r in select unnest(array[
      'appointment.queue_entries','appointment.queue_counters','appointment.appointments','appointment.schedules',
      'appointment.schedule_overrides','appointment.practitioner_branches','appointment.practitioners',
      'billing.allocation','billing.payment_tender','billing.payment','billing.discount','billing.charge_suggestion',
      'billing.payment_link','billing.bill_line','billing.bill','billing.billing_account','billing.approval_request',
      'billing.counter_close','billing.counter_session','billing.counter','billing.price_list_item','billing.service_item',
      'billing.bill_number_series','billing.branch_profile','billing.wallet',
      'patient.patient_phones','patient.patients','privacy.patient_alias',
      'identity.memberships','identity.user_profiles','identity.invite_links','identity.branches','identity.tenants']) t loop
    execute format('alter table %s disable trigger user', r.t);
  end loop;

  delete from appointment.queue_entries where tenant_id = T
     and (appointment_id in (select id from rm_appt) or patient_id in (select id from rm_patient) or branch_id in (select id from rm_branch));
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('queue_entries', n);
  delete from appointment.queue_counters where tenant_id = T and branch_id in (select id from rm_branch);

  delete from billing.allocation where bill_id in (select id from rm_bill) or payment_id in (select id from rm_payment);
  delete from billing.payment_tender where payment_id in (select id from rm_payment);
  delete from billing.payment where id in (select id from rm_payment) and refund_of_payment_id is not null;
  delete from billing.payment where id in (select id from rm_payment);
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('payments', n);
  delete from billing.discount where bill_id in (select id from rm_bill);
  delete from billing.charge_suggestion where bill_id in (select id from rm_bill);
  delete from billing.payment_link where bill_id in (select id from rm_bill) or counter_session_id in (select id from rm_session);
  delete from billing.bill_line where bill_id in (select id from rm_bill);
  delete from billing.bill where id in (select id from rm_bill) and reverses_bill_id is not null;
  delete from billing.bill where id in (select id from rm_bill);
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('bills', n);
  delete from billing.billing_account where id in (select id from rm_account);
  delete from billing.counter_close where counter_session_id in (select id from rm_session);
  delete from billing.counter_session where id in (select id from rm_session);
  delete from billing.counter where tenant_id = T and branch_id in (select id from rm_branch);
  delete from billing.approval_request where id in (select id from rm_approval);
  delete from billing.wallet where holder_patient_id in (select id from rm_patient);
  delete from billing.price_list_item where tenant_id = T
     and (service_item_id in (select id from rm_item) or practitioner_id in (select id from rm_prac));
  delete from billing.service_item where tenant_id = T and id in (select id from rm_item);
  delete from billing.bill_number_series where tenant_id = T and branch_id in (select id from rm_branch);
  delete from billing.branch_profile where tenant_id = T and branch_id in (select id from rm_branch);
  delete from billing.price_list where tenant_id = T and branch_id in (select id from rm_branch);

  delete from appointment.appointments where id in (select id from rm_appt) and parent_appointment_id is not null;
  delete from appointment.appointments where id in (select id from rm_appt);
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('appointments', n);
  delete from appointment.schedule_overrides where tenant_id = T
     and (practitioner_id in (select id from rm_prac) or branch_id in (select id from rm_branch));
  delete from appointment.schedules where tenant_id = T
     and (practitioner_id in (select id from rm_prac) or branch_id in (select id from rm_branch));
  delete from appointment.practitioner_branches where tenant_id = T
     and (practitioner_id in (select id from rm_prac) or branch_id in (select id from rm_branch));
  delete from appointment.practitioners where tenant_id = T and id in (select id from rm_prac);
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('practitioners', n);

  delete from privacy.patient_alias where tenant_id = T
     and (from_patient_id in (select id from rm_patient) or to_patient_id in (select id from rm_patient));
  delete from patient.patient_phones where patient_id in (select id from rm_patient);
  delete from patient.patients where id in (select id from rm_patient);
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('patients', n);

  delete from identity.memberships where tenant_id = T and (user_id in (select id from rm_user) or branch_id in (select id from rm_branch));
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('memberships', n);
  delete from identity.invite_links where branch_id in (select id from rm_branch);
  delete from identity.user_profiles where id in (select id from rm_user);
  delete from auth.identities where user_id in (select id from rm_user);
  delete from auth.sessions where user_id in (select id from rm_user);
  delete from auth.users where id in (select id from rm_user);
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('auth_users', n);
  delete from identity.branches where tenant_id = T and id in (select id from rm_branch);
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('branches', n);

  update identity.tenants set settings = settings - 'demo_seed' where id = T;

  for r in select unnest(array[
      'appointment.queue_entries','appointment.queue_counters','appointment.appointments','appointment.schedules',
      'appointment.schedule_overrides','appointment.practitioner_branches','appointment.practitioners',
      'billing.allocation','billing.payment_tender','billing.payment','billing.discount','billing.charge_suggestion',
      'billing.payment_link','billing.bill_line','billing.bill','billing.billing_account','billing.approval_request',
      'billing.counter_close','billing.counter_session','billing.counter','billing.price_list_item','billing.service_item',
      'billing.bill_number_series','billing.branch_profile','billing.wallet',
      'patient.patient_phones','patient.patients','privacy.patient_alias',
      'identity.memberships','identity.user_profiles','identity.invite_links','identity.branches','identity.tenants']) t loop
    execute format('alter table %s enable trigger user', r.t);
  end loop;

  raise notice 'demo-seed removed: %', v_counts;
  if coalesce(current_setting('demo.dry_run', true), '') = 'on' then
    raise exception 'DRY RUN (rolled back): %', v_counts using errcode = 'P0001';
  end if;
end $$;
