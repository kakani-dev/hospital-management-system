-- cross-schema: approved (pharmacy schema hosted by the inventory service per docs/adr/0004-pharmacy-dispensing-in-inventory.md; reads clinical.consultations, patient.patients, appointment.practitioners inside security-definer functions only, and identity helpers has_tenant_permission / current_tenant_ids / can_access_branch; uses inventory.branch_today for the branch-local calendar day)
-- #188: prescriptions expire for dispensing. Tenant setting rx_validity_days (default 30).
-- An Rx finalized on local day D can be dispensed through D + N; from D + N + 1 it is expired:
-- the open queue hides it and pharmacy.dispense raises 55000 'prescription expired on <D+N>'.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create table if not exists pharmacy.tenant_setting (
  tenant_id uuid primary key references identity.tenants (id),
  rx_validity_days integer not null default 30 check (rx_validity_days between 1 and 365),
  updated_by uuid,
  updated_on timestamptz not null default now()
);
alter table pharmacy.tenant_setting enable row level security;
revoke all on pharmacy.tenant_setting from public, anon, authenticated;

create or replace function pharmacy.rx_validity_days(p_tenant_id uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce((select s.rx_validity_days from pharmacy.tenant_setting s where s.tenant_id = p_tenant_id), 30)
$$;

-- Last branch-local day on which the prescription may be dispensed.
create or replace function pharmacy.rx_valid_through(p_tenant_id uuid, p_branch_id uuid, p_finalized_on timestamptz)
returns date language sql stable security definer set search_path = '' as $$
  select inventory.branch_today(p_branch_id, p_finalized_on) + pharmacy.rx_validity_days(p_tenant_id)
$$;

revoke execute on function pharmacy.rx_validity_days(uuid) from public, anon, authenticated;
revoke execute on function pharmacy.rx_valid_through(uuid, uuid, timestamptz) from public, anon, authenticated;

create or replace function pharmacy.get_settings(p_tenant_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform pharmacy.assert_permission(p_tenant_id, 'pharmacy.view');
  return jsonb_build_object('rxValidityDays', pharmacy.rx_validity_days(p_tenant_id));
end;
$$;

create or replace function pharmacy.set_rx_validity_days(p_tenant_id uuid, p_days integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids()) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not identity.has_tenant_permission(p_tenant_id, 'settings.manage') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_days is null or p_days < 1 or p_days > 365 then
    raise exception 'rx validity must be between 1 and 365 days' using errcode = '22023';
  end if;
  insert into pharmacy.tenant_setting (tenant_id, rx_validity_days, updated_by, updated_on)
  values (p_tenant_id, p_days, auth.uid(), now())
  on conflict (tenant_id) do update
    set rx_validity_days = excluded.rx_validity_days, updated_by = excluded.updated_by, updated_on = now();
  return jsonb_build_object('rxValidityDays', p_days);
end;
$$;

revoke execute on function pharmacy.get_settings(uuid) from public, anon, authenticated;
revoke execute on function pharmacy.set_rx_validity_days(uuid, integer) from public, anon, authenticated;
grant execute on function pharmacy.get_settings(uuid) to hms_svc_inventory;
grant execute on function pharmacy.set_rx_validity_days(uuid, integer) to hms_svc_inventory;

-- Dispense path: the locked load is used only by pharmacy.dispense, after which stock moves.
-- Idempotent replays use the unlocked load and still return the earlier result.
create or replace function pharmacy.load_rx(p_tenant_id uuid, p_id uuid, p_lock boolean default false)
returns clinical.consultations language plpgsql security definer set search_path = '' as $$
declare
  v clinical.consultations%rowtype;
  v_through date;
begin
  if p_lock then
    select * into v from clinical.consultations
    where id = p_id and tenant_id = p_tenant_id and not is_deleted for update;
  else
    select * into v from clinical.consultations
    where id = p_id and tenant_id = p_tenant_id and not is_deleted;
  end if;
  if v.id is null or v.status <> 'finalized' then
    raise exception 'prescription not found' using errcode = 'P0002';
  end if;
  if not identity.can_access_branch(p_tenant_id, v.branch_id) then
    raise exception 'this prescription is at a branch you cannot access' using errcode = '42501';
  end if;
  if p_lock then
    v_through := pharmacy.rx_valid_through(p_tenant_id, v.branch_id, v.finalized_on);
    if inventory.branch_today(v.branch_id) > v_through then
      raise exception 'prescription expired on %', to_char(v_through, 'YYYY-MM-DD') using errcode = '55000';
    end if;
  end if;
  return v;
end;
$$;
revoke execute on function pharmacy.load_rx(uuid, uuid, boolean) from public, anon, authenticated;

create or replace function pharmacy.list_queue(p_tenant_id uuid, p_branch_id uuid, p_status text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_status text := coalesce(nullif(btrim(p_status), ''), 'open');
  v_days integer;
begin
  perform pharmacy.assert_permission(p_tenant_id, 'pharmacy.view');
  if v_status not in ('open', 'all', 'pending', 'partial', 'dispensed') then
    raise exception 'status must be open, all, pending, partial, or dispensed' using errcode = '22023';
  end if;
  if p_branch_id is not null and not identity.can_access_branch(p_tenant_id, p_branch_id) then
    raise exception 'branch out of scope' using errcode = '42501';
  end if;
  v_days := pharmacy.rx_validity_days(p_tenant_id);
  return coalesce((
    select jsonb_agg(q.row order by q.finalized_on, q.id)
    from (
      select c.id, c.finalized_on, jsonb_build_object(
        'id', c.id, 'branchId', c.branch_id, 'patientId', c.patient_id,
        'patientName', p.first_name || ' ' || p.last_name, 'patientMrn', p.mrn,
        'doctorName', pr.display_name, 'finalizedOn', c.finalized_on,
        'validThrough', d.valid_through, 'expired', d.today > d.valid_through,
        'lineCount', (select count(*) from clinical.prescription_lines l
                      where l.consultation_id = c.id and not l.is_deleted),
        'status', s.status) as row
      from clinical.consultations c
      join patient.patients p on p.id = c.patient_id and p.tenant_id = c.tenant_id
      join appointment.practitioners pr on pr.id = c.practitioner_id
      cross join lateral (select inventory.branch_today(c.branch_id, c.finalized_on) + v_days as valid_through,
                                 inventory.branch_today(c.branch_id) as today) d
      cross join lateral (select pharmacy.rx_status(c.id) as status) s
      where c.tenant_id = p_tenant_id
        and c.status = 'finalized' and not c.is_deleted
        and (p_branch_id is null or c.branch_id = p_branch_id)
        and identity.can_access_branch(p_tenant_id, c.branch_id)
        and not pharmacy.is_superseded(c.id)
        and exists (select 1 from clinical.prescription_lines l where l.consultation_id = c.id and not l.is_deleted)
        -- Expired prescriptions leave the working queue (open / pending / partial); history views keep them.
        and (v_status in ('all', 'dispensed') or d.today <= d.valid_through)
        and (v_status = 'all'
             or (v_status = 'open' and s.status in ('pending', 'partial'))
             or s.status = v_status)
      order by c.finalized_on, c.id
      limit 200
    ) q), '[]'::jsonb);
end;
$$;
