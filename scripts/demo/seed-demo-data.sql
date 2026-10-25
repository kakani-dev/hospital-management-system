-- =============================================================================
-- MediCore DEMO DATA seed. SYNTHETIC DATA ONLY: fake Indian names, +91 90000 phones that are
-- reserved-looking test numbers, @demo-seed.example.com emails, format-valid fake ABHA numbers.
--
-- Target: the existing tenant 'MediCore Demo Hospital' (77519cf6-1d9b-4954-8bc6-f29bbb734786).
-- Never create a new demo tenant. Run as the database owner (postgres), AFTER the SQL printed by
-- scripts/demo/create-demo-logins.py. See scripts/demo/README.md.
--
-- Idempotent: every section is versioned in identity.tenants.settings -> 'demo_seed' and is skipped
-- when already applied. To add data for a new feature (e.g. visit types), append a new section
-- guarded by "if v_ver < N" and bump the version at the end of it.
--
-- Tags (used by remove-demo-data.sql): seeded patients have emails @demo-seed.example.com, seeded
-- appointments have reason '[demo-seed] ...', seeded branches/practitioners/service items are listed
-- in settings.demo_seed.
--
-- Commands go through the app's own SQL functions (appointment state machine, check_in,
-- billing.ensure_draft/add_line/request_discount/finalize_bill/collect_payment/request_refund), so
-- rules, audit columns and outbox events stay consistent. Those functions stamp now(); history is
-- then BACKDATED by rewriting only timestamp columns of seeded rows with user triggers disabled
-- inside this transaction (the one place invariants cannot be satisfied through the API).
-- =============================================================================
do $seed$
declare
  T constant uuid := '77519cf6-1d9b-4954-8bc6-f29bbb734786';
  ADMIN uuid;
  v_ver int;
  HYD uuid; BLR uuid; CHN uuid;
  v_docs uuid[]; v_doc_branch uuid[];
  v_new_pracs uuid[] := '{}';
  v_items uuid[] := '{}';
  v_ecg uuid; v_cbc uuid;
  v_pat uuid[]; v_pat_branch uuid[];
  first_m text[] := array['Aarav','Vihaan','Arjun','Rohan','Karthik','Sai','Rahul','Aditya','Venkat','Suresh','Mahesh','Naveen','Pranav','Harish','Rakesh','Anil'];
  first_f text[] := array['Ananya','Diya','Saanvi','Lakshmi','Divya','Sneha','Pooja','Kavya','Meera','Swathi','Bhavana','Keerthi','Nandini','Revathi','Shreya','Priyanka'];
  last_n text[] := array['Reddy','Rao','Sharma','Iyer','Nair','Gupta','Naidu','Kumar','Menon','Pillai','Hegde','Shetty','Joshi','Patel','Verma','Chowdary','Krishnan','Bhat'];
  i int; k int; v_day int; v_br uuid; v_doc uuid; v_p uuid; v_a uuid; v_start timestamptz;
  v_r float; v_status text; v_sex text; v_fn text;
  v_bill uuid; v_acct uuid; v_total bigint; v_pay bigint; v_mode text; v_sess uuid; v_cashier uuid;
  v_pay_id uuid; v_j jsonb; v_q int; v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_ts timestamptz;
begin
  if not exists (select 1 from identity.tenants where id = T and not is_deleted) then
    raise exception 'demo tenant % not found', T;
  end if;
  select coalesce((settings -> 'demo_seed' ->> 'version')::int, 0) into v_ver from identity.tenants where id = T;
  if v_ver >= 1 then
    raise notice 'demo seed v1 already applied; nothing to do';
    return;
  end if;
  perform setseed(0.2026);

  select m.user_id into ADMIN from identity.memberships m join identity.user_profiles p on p.id = m.user_id
   where m.tenant_id = T and p.email = 'demo.admin@demo.medicore.test' and m.role = 'tenant_admin';
  perform set_config('hms.actor_id', ADMIN::text, true);

  -- ---------------------------------------------------------------- branches (to 3) -------
  select id into HYD from identity.branches where tenant_id = T and code = 'hyd-main';
  insert into identity.branches (tenant_id, code, name, address)
  select T, v.code, v.name, v.addr from (values
    ('blr-demo', 'Bengaluru Koramangala', '80 Feet Road, Koramangala, Bengaluru (synthetic)'),
    ('chn-demo', 'Chennai T. Nagar', 'Usman Road, T. Nagar, Chennai (synthetic)')) v(code, name, addr)
  where (select count(*) from identity.branches where tenant_id = T and not is_deleted) < 3
    and not exists (select 1 from identity.branches b where b.tenant_id = T and b.code = v.code);
  select id into BLR from identity.branches where tenant_id = T and code = 'blr-demo';
  select id into CHN from identity.branches where tenant_id = T and code = 'chn-demo';

  -- ---------------------------------------------------------------- staff memberships ------
  insert into identity.memberships (tenant_id, user_id, branch_id, role, status)
  select T, p.id, case split_part(split_part(p.email, '@', 1), '.', 2) when 'hyd' then HYD when 'blr' then BLR when 'chn' then CHN
                     else case p.email when 'dr.karthik@demo-seed.example.com' then CHN else BLR end end,
         case split_part(p.email, '.', 1) when 'reception' then 'receptionist' when 'nurse' then 'nurse'
                     when 'billing' then 'billing' else 'doctor' end, 'active'
  from identity.user_profiles p
  where p.email like '%@demo-seed.example.com'
    and not exists (select 1 from identity.memberships m where m.tenant_id = T and m.user_id = p.id);

  -- Act as the demo admin from here on (memberships above are owner-created as active, like seed.sql).
  perform set_config('request.jwt.claim.sub', ADMIN::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', ADMIN, 'role', 'authenticated')::text, true);

  -- Distinct bill-number prefixes for the new branches (the series is per branch, the number is unique per tenant).
  insert into billing.branch_profile (tenant_id, branch_id, doc_prefix, created_by, updated_by)
  select T, b.id, case b.code when 'blr-demo' then 'DBLR' else 'DCHN' end, ADMIN, ADMIN
  from identity.branches b where b.tenant_id = T and b.code in ('blr-demo', 'chn-demo')
  on conflict (tenant_id, branch_id) do update set doc_prefix = excluded.doc_prefix
    where billing.branch_profile.doc_prefix not in ('DBLR', 'DCHN');

  -- ---------------------------------------------------------------- practitioners (5 -> 8) -
  with ins as (
    insert into appointment.practitioners (tenant_id, user_id, display_name, specialty)
    select T, p.id, v.name, v.spec
    from (values ('dr.arjun@demo-seed.example.com', 'Dr. Arjun Hegde', 'Orthopaedics'),
                 ('dr.meenakshi@demo-seed.example.com', 'Dr. Meenakshi Iyer', 'Gynaecology'),
                 ('dr.karthik@demo-seed.example.com', 'Dr. Karthik Subramanian', 'Dermatology')) v(email, name, spec)
    join identity.user_profiles p on p.email = v.email
    returning id, user_id)
  select array_agg(id) into v_new_pracs from ins;
  insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id)
  select T, pr.id, m.branch_id from appointment.practitioners pr
  join identity.memberships m on m.tenant_id = T and m.user_id = pr.user_id and m.role = 'doctor'
  where pr.id = any (v_new_pracs);
  -- Two Hyderabad doctors also visit Bengaluru / Chennai on Saturdays (multi-branch demo).
  insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id)
  values (T, '82ede72c-fe09-41d2-a516-531df98f7f17', BLR), (T, '8a78c191-fa86-49ae-94fa-a1dc2f10fc1f', CHN)
  on conflict do nothing;
  insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from)
  select T, pb.practitioner_id, pb.branch_id, wd, '09:00', '17:00', 20, date '2026-07-01'
  from appointment.practitioner_branches pb cross join generate_series(1, 6) wd
  where pb.practitioner_id = any (v_new_pracs);

  -- doctor -> home branch, used for booking (visiting doctors stay at Hyderabad for history)
  select array_agg(pr.id order by pr.display_name), array_agg(coalesce(nb.branch_id, HYD) order by pr.display_name)
    into v_docs, v_doc_branch
  from appointment.practitioners pr
  left join lateral (select pb.branch_id from appointment.practitioner_branches pb
                     where pb.practitioner_id = pr.id and pr.id = any (v_new_pracs) limit 1) nb on true
  where pr.tenant_id = T and not pr.is_deleted;

  -- ---------------------------------------------------------------- price catalogue -------
  perform billing.ensure_defaults(T);
  v_ecg := (billing.upsert_service_item(T, jsonb_build_object('name', 'ECG (12 lead)', 'category', 'procedure')) ->> 'id')::uuid;
  v_cbc := (billing.upsert_service_item(T, jsonb_build_object('name', 'Complete blood count', 'category', 'lab')) ->> 'id')::uuid;
  v_items := array[v_ecg, v_cbc];
  perform billing.add_price(T, jsonb_build_object('serviceItemId', v_ecg, 'unitPricePaise', 35000, 'effectiveFrom', '2026-01-01'));
  perform billing.add_price(T, jsonb_build_object('serviceItemId', v_cbc, 'unitPricePaise', 45000, 'effectiveFrom', '2026-01-01'));
  for i in 1 .. coalesce(array_length(v_new_pracs, 1), 0) loop
    perform billing.add_price(T, jsonb_build_object(
      'serviceItemId', (select id from billing.service_item where tenant_id = T and code = 'CONSULT'),
      'practitionerId', v_new_pracs[i], 'unitPricePaise', (array[80000, 70000, 60000])[i], 'effectiveFrom', '2026-01-01'));
  end loop;

  -- ---------------------------------------------------------------- patients (+110) -------
  for i in 1 .. 110 loop
    v_sex := case when random() < 0.5 then 'female' else 'male' end;
    v_fn := case v_sex when 'female' then first_f[1 + floor(random() * 16)::int] else first_m[1 + floor(random() * 16)::int] end;
    v_br := case when i % 10 < 5 then HYD when i % 10 < 8 then BLR else CHN end;
    insert into patient.patients (tenant_id, registered_branch_id, mrn, first_name, last_name, date_of_birth, sex, phone, email, abha_number)
    values (T, v_br, null, v_fn, last_n[1 + floor(random() * 18)::int],
            date '1950-01-01' + floor(random() * 25000)::int, v_sex,
            '+9190000' || lpad((10000 + i)::text, 5, '0'),
            'patient' || lpad(i::text, 3, '0') || '@demo-seed.example.com',
            case when i % 3 = 0 then '91-' || lpad((9000 + i)::text, 4, '0') || '-' || lpad((i * 37 % 10000)::text, 4, '0') || '-' || lpad((i * 71 % 10000)::text, 4, '0') end);
  end loop;
  select array_agg(id order by email), array_agg(registered_branch_id order by email) into v_pat, v_pat_branch
  from patient.patients where tenant_id = T and email like '%@demo-seed.example.com' and deleted_at is null;

  -- ---------------------------------------------------------------- appointments (340) ----
  create temp table demo_appt (id uuid, day int, status text, branch uuid) on commit drop;
  for i in 0 .. 339 loop
    v_day := -90 + (i * 97 / 339);
    k := 1 + (i % array_length(v_docs, 1));
    v_doc := v_docs[k]; v_br := v_doc_branch[k];
    -- a patient registered at that branch
    loop
      v_p := v_pat[1 + floor(random() * array_length(v_pat, 1))::int];
      exit when v_pat_branch[array_position(v_pat, v_p)] = v_br or random() < 0.1;
    end loop;
    v_start := ((v_today + v_day)::timestamp + time '09:00' + ((i % 24) * interval '20 minutes')) at time zone 'Asia/Kolkata';
    -- skip past slots already taken by existing (hand-made) demo appointments
    while exists (select 1 from appointment.appointments x where x.tenant_id = T and x.practitioner_id = v_doc
                  and x.status in ('booked', 'checked_in', 'in_consultation', 'completed')
                  and tstzrange(x.starts_at, x.ends_at, '[)') && tstzrange(v_start - interval '20 minutes', v_start + interval '40 minutes', '[)')) loop
      v_start := v_start + interval '9 hours';   -- evening clinic slot, same day
      exit when v_start > ((v_today + v_day)::timestamp + time '23:00') at time zone 'Asia/Kolkata';
    end loop;
    insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason)
    values (T, v_br, v_doc, v_p, v_start, v_start + interval '20 minutes',
            '[demo-seed] ' || (array['Fever and cough','Follow-up review','Back pain','Routine check-up','Chest discomfort','Skin rash','Knee pain','BP review','Diabetes review','Headache'])[1 + floor(random() * 10)::int])
    returning id into v_a;
    v_r := random();
    v_status := case
      when v_day < 0 then case when v_r < 0.78 then 'completed' when v_r < 0.89 then 'no_show' else 'cancelled' end
      when v_day = 0 then case when i % 4 = 0 then 'completed' when i % 4 = 1 then 'in_consultation' when i % 4 = 2 then 'checked_in' else 'booked' end
      else case when v_r < 0.08 then 'cancelled' else 'booked' end end;
    insert into demo_appt values (v_a, v_day, v_status, v_br);
  end loop;

  -- state machine, past days: booked -> checked_in -> in_consultation -> completed / no_show / cancelled
  for v_a, v_day, v_status, v_br in select id, day, status, branch from demo_appt where status <> 'booked' order by day loop
    if v_status = 'cancelled' then
      update appointment.appointments set status = 'cancelled', cancel_reason = 'Patient requested (demo)' where id = v_a;
    elsif v_status = 'no_show' then
      update appointment.appointments set status = 'no_show' where id = v_a;
    elsif v_day = 0 then
      -- today's live queue through the real check-in command (issues the token)
      perform appointment.check_in(T, v_br, (select patient_id from appointment.appointments where id = v_a), v_a, null);
      if v_status in ('in_consultation', 'completed') then
        update appointment.appointments set status = 'in_consultation' where id = v_a;
        if v_status = 'completed' then
          update appointment.appointments set status = 'completed' where id = v_a;
        end if;
      end if;
    else
      perform set_config('appointment.check_in', v_a::text, true);
      update appointment.appointments set status = 'checked_in' where id = v_a;
      perform set_config('appointment.check_in', '', true);
      update appointment.appointments set status = 'in_consultation' where id = v_a;
      update appointment.appointments set status = 'completed' where id = v_a;
      select coalesce(max(token_no), 0) + 1 into v_q from appointment.queue_entries
       where tenant_id = T and branch_id = v_br and queue_date = v_today + v_day;
      insert into appointment.queue_entries (tenant_id, branch_id, queue_date, token_no, patient_id, appointment_id, practitioner_id, status)
      select T, v_br, v_today + v_day, v_q, patient_id, id, practitioner_id, 'done' from appointment.appointments where id = v_a;
    end if;
  end loop;
  -- today's queue rows follow the appointment status
  update appointment.queue_entries q set status = case a.status when 'completed' then 'done' else a.status end
  from appointment.appointments a join demo_appt d on d.id = a.id
  where q.appointment_id = a.id and d.day = 0 and a.status in ('in_consultation', 'completed') and q.status = 'waiting';

  -- ---------------------------------------------------------------- billing ---------------
  create temp table demo_pay (payment uuid, bill uuid, day int) on commit drop;
  for v_a, v_day, v_br in select id, day, branch from demo_appt where status = 'completed' order by day loop
    v_j := billing.ensure_draft(T, v_a);
    v_bill := coalesce(v_j ->> 'billId', v_j ->> 'id')::uuid; v_acct := (v_j ->> 'accountId')::uuid;
    if random() < 0.25 then perform billing.add_line(T, v_bill, jsonb_build_object('serviceItemId', v_ecg)); end if;
    if random() < 0.30 then perform billing.add_line(T, v_bill, jsonb_build_object('serviceItemId', v_cbc)); end if;
    if random() < 0.08 then
      perform billing.request_discount(T, v_bill, jsonb_build_object('kind', 'percent_bp', 'value', 1000, 'reasonCode', 'senior_citizen'));
    end if;
    perform billing.finalize_bill(T, v_bill);
    v_total := (billing.bill_json(v_bill) ->> 'totalPaise')::bigint;
    v_r := random();
    continue when v_r < 0.05;                                  -- unpaid / outstanding
    v_pay := case when v_r < 0.09 then v_total / 2 else v_total end;  -- a few part-paid
    v_mode := case when random() < 0.4 then 'cash' when random() < 0.75 then 'upi' else 'card' end;
    v_sess := null;
    if v_mode = 'cash' then
      select m.user_id into v_cashier from identity.memberships m
       where m.tenant_id = T and m.branch_id = v_br and m.role = 'billing' limit 1;
      if v_cashier is null then v_mode := 'upi'; else
        perform set_config('hms.actor_id', v_cashier::text, true);
        perform set_config('request.jwt.claim.sub', v_cashier::text, true);
        perform set_config('request.jwt.claims', jsonb_build_object('sub', v_cashier, 'role', 'authenticated')::text, true);
        v_sess := (billing.ensure_cashier_session(T, v_br) ->> 'id')::uuid;
        perform set_config('hms.actor_id', ADMIN::text, true);
        perform set_config('request.jwt.claim.sub', ADMIN::text, true);
        perform set_config('request.jwt.claims', jsonb_build_object('sub', ADMIN, 'role', 'authenticated')::text, true);
      end if;
    end if;
    v_j := billing.collect_payment(T, gen_random_uuid(), jsonb_build_object(
      'accountId', v_acct, 'kind', 'payment', 'counterSessionId', v_sess,
      'tenders', jsonb_build_array(jsonb_build_object('mode', v_mode, 'amountPaise', v_pay,
                   'reference', case when v_mode <> 'cash' then 'DEMO-' || substr(md5(v_bill::text), 1, 10) end)),
      'allocations', jsonb_build_array(jsonb_build_object('billId', v_bill, 'amountPaise', v_pay))));
    v_pay_id := coalesce(v_j ->> 'paymentId', v_j ->> 'id')::uuid;
    insert into demo_pay values (v_pay_id, v_bill, v_day);
    if random() < 0.04 and v_mode <> 'cash' then
      perform billing.request_refund(T, v_pay_id, jsonb_build_object('amountPaise', v_pay / 2, 'mode', v_mode, 'reference', 'DEMO-REFUND'));
    end if;
  end loop;

  -- ---------------------------------------------------------------- backdate history ------
  -- Commands above stamped now(); move seeded rows to their visit time. Only timestamp columns of
  -- rows created by this run are touched.
  alter table appointment.appointments disable trigger user;
  update appointment.appointments a set
    checked_in_at = case when a.checked_in_at is not null then a.starts_at - interval '10 minutes' end,
    started_at = case when a.started_at is not null then a.starts_at end,
    completed_at = case when a.completed_at is not null then a.starts_at + interval '18 minutes' end,
    cancelled_at = case when a.cancelled_at is not null then least(a.starts_at - interval '1 day', now()) end,
    created_on = least(a.starts_at - interval '3 days', now()), created_at = least(a.starts_at - interval '3 days', now())
  from demo_appt d where d.id = a.id and d.day < 0;
  alter table appointment.appointments enable trigger user;
  alter table appointment.queue_entries disable trigger user;
  update appointment.queue_entries q set checked_in_at = a.checked_in_at, called_at = a.started_at, completed_at = a.completed_at,
    created_on = a.checked_in_at, created_at = a.checked_in_at
  from appointment.appointments a join demo_appt d on d.id = a.id where q.appointment_id = a.id and d.day < 0;
  alter table appointment.queue_entries enable trigger user;
  alter table billing.bill disable trigger user;
  update billing.bill b set finalized_at = a.completed_at + interval '5 minutes', created_on = a.completed_at
  from billing.billing_account ac join appointment.appointments a on a.id = ac.source_ref_id join demo_appt d on d.id = a.id
  where b.account_id = ac.id and ac.source_ref_type = 'appointment' and d.day < 0;
  alter table billing.bill enable trigger user;
  alter table billing.payment disable trigger user;
  update billing.payment p set received_at = b.finalized_at + interval '3 minutes', created_on = b.finalized_at + interval '3 minutes'
  from demo_pay dp join billing.bill b on b.id = dp.bill where p.id = dp.payment and dp.day < 0;
  update billing.payment r set received_at = p.received_at + interval '2 days', created_on = p.received_at + interval '2 days'
  from billing.payment p join demo_pay dp on dp.payment = p.id where r.refund_of_payment_id = p.id and dp.day < 0;
  alter table billing.payment enable trigger user;

  update identity.tenants set settings = coalesce(settings, '{}'::jsonb) || jsonb_build_object('demo_seed', jsonb_build_object(
    'version', 1, 'seeded_on', now(), 'branches', jsonb_build_array(BLR, CHN),
    'practitioners', to_jsonb(v_new_pracs), 'service_items', to_jsonb(v_items)))
  where id = T;
  raise notice 'demo seed v1 applied';
end
$seed$;
