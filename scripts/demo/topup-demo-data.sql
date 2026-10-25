-- Demo top-up for MediCore Demo Hospital (existing tenant only; never creates a tenant).
-- Synthetic data. Idempotent: GSTINs only fill nulls; the queue top-up skips when today
-- (IST) already has >= 15 queue entries. Rows are tagged '[demo-seed]' so remove-demo-data.sql cleans them.
-- No triggers are disabled. MRNs are not touched (patient.guard_mrn makes them immutable;
-- the DEMO-HYD prefix is the tenant-wide MRN prefix, not a branch code).
do $$
declare
  T constant uuid := '77519cf6-1d9b-4954-8bc6-f29bbb734786';
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  r record; k int; v_p uuid; v_start timestamptz; v_a uuid; i int := 0; v_status text;
  ADMIN uuid; VT_NEW uuid; VT_FU uuid; VT_REV uuid; VT_TELE uuid;
begin
  if not exists (select 1 from identity.tenants where id = T) then raise exception 'demo tenant missing'; end if;
  select m.user_id into ADMIN from identity.memberships m join identity.user_profiles p on p.id = m.user_id
   where m.tenant_id = T and p.email = 'demo.admin@demo.medicore.test' and m.role = 'tenant_admin';
  if ADMIN is null then raise exception 'demo admin missing'; end if;
  perform set_config('hms.actor_id', ADMIN::text, true);
  perform set_config('request.jwt.claim.sub', ADMIN::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', ADMIN, 'role', 'authenticated')::text, true);

  -- 1. synthetic GSTINs (PAN ZZZCM9999M is fake; state code = branch state; checksum valid)
  update billing.branch_profile bp set gstin = v.g, legal_name = coalesce(bp.legal_name, 'MediCore Demo Hospital Pvt Ltd (synthetic)')
  from identity.branches b, (values ('hyd-main','36ZZZCM9999M1ZN'),('blr-demo','29ZZZCM9999M1ZI'),('chn-demo','33ZZZCM9999M1ZT')) v(code, g)
  where b.id = bp.branch_id and b.tenant_id = T and bp.tenant_id = T and b.code = v.code and bp.gstin is null;

  select id into VT_NEW  from appointment.visit_types where tenant_id = T and code = 'new_consult';
  select id into VT_FU   from appointment.visit_types where tenant_id = T and code = 'follow_up';
  select id into VT_REV  from appointment.visit_types where tenant_id = T and code = 'review';
  select id into VT_TELE from appointment.visit_types where tenant_id = T and code = 'teleconsult';

  -- 2. today's OPD queue to ~15 checked-in patients, round-robin over doctor x branch
  if (select count(*) from appointment.queue_entries where tenant_id = T and queue_date = v_today) < 15 then
    for r in select pb.practitioner_id doc, pb.branch_id br, row_number() over () n
             from appointment.practitioner_branches pb cross join generate_series(1, 4)
             where pb.tenant_id = T order by random() limit 15 loop
      i := i + 1;
      select p.id into v_p from patient.patients p
       where p.tenant_id = T and p.deleted_at is null and p.registered_branch_id = r.br
         and not exists (select 1 from appointment.appointments a where a.tenant_id = T and a.patient_id = p.id
                         and (a.starts_at at time zone 'Asia/Kolkata')::date = v_today)
       order by random() limit 1;
      continue when v_p is null;
      v_start := (v_today::timestamp + time '09:00' + (i * 40) * interval '1 minute') at time zone 'Asia/Kolkata';
      while exists (select 1 from appointment.appointments x where x.tenant_id = T and x.practitioner_id = r.doc
                    and x.status in ('booked','checked_in','in_consultation','completed')
                    and tstzrange(x.starts_at, x.ends_at, '[)') && tstzrange(v_start, v_start + interval '20 minutes', '[)')) loop
        v_start := v_start + interval '20 minutes';
      end loop;
      insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason,
                                            visit_type_id, consultation_fee_paise, granted_follow_up_days, granted_follow_up_fee_paise)
      values (T, r.br, r.doc, v_p, v_start, v_start + interval '20 minutes',
              '[demo-seed] ' || (array['Fever and cough','Back pain','Routine check-up','Skin rash','Knee pain','BP review','Diabetes review','Headache'])[1 + (i % 8)],
              VT_NEW, 50000, 7, 0)
      returning id into v_a;
      perform appointment.check_in(T, r.br, v_p, v_a, null);
      v_status := case when i % 4 = 0 then 'completed' when i % 4 = 1 then 'in_consultation' else 'waiting' end;
      if v_status <> 'waiting' then
        update appointment.appointments set status = 'in_consultation' where id = v_a;
        if v_status = 'completed' then update appointment.appointments set status = 'completed' where id = v_a; end if;
        update appointment.queue_entries set status = case v_status when 'completed' then 'done' else v_status end
         where appointment_id = v_a and status = 'waiting';
      end if;
    end loop;
  end if;

  -- 4. visit-type appointments over the next days: free follow-up, review, teleconsult
  if not exists (select 1 from appointment.appointments where tenant_id = T and visit_type_id in (VT_FU, VT_REV, VT_TELE)) then
    for r in select a.practitioner_id doc, a.branch_id br, a.patient_id pat, row_number() over (order by a.starts_at) n
             from appointment.appointments a
             where a.tenant_id = T and a.visit_type_id = VT_NEW and a.status = 'completed'
               and (a.starts_at at time zone 'Asia/Kolkata')::date = v_today limit 3 loop
      v_start := ((v_today + r.n::int)::timestamp + time '11:00') at time zone 'Asia/Kolkata';
      for k in 1..20 loop  -- next free slot; the commitment trigger rejects clashes across branches
       begin
      insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason,
                                            visit_type_id, consultation_fee_paise, granted_follow_up_days, granted_follow_up_fee_paise)
      select T, r.br, r.doc, r.pat, v_start, v_start + interval '20 minutes', '[demo-seed] ' || x.why, x.vt, x.fee, x.d, x.ff
      from (values (1, VT_FU, 0::bigint, null::smallint, null::bigint, 'Free follow-up inside 7-day window'),
                   (2, VT_REV, 30000::bigint, 14::smallint, 10000::bigint, 'Lab report review'),
                   (3, VT_TELE, 40000::bigint, 3::smallint, 0::bigint, 'Teleconsult check-in')) x(n, vt, fee, d, ff, why)
      where x.n = r.n;
        exit;
       exception when exclusion_violation then v_start := v_start + interval '20 minutes';
       end;
      end loop;
    end loop;
  end if;
end $$;
