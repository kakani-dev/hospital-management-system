-- cross-schema: approved (no new cross-schema reads; same identity.* helpers as 20261025220100:
-- branch_exists_v1, current_tenant_ids, has_tenant_permission, can_access_branch, branch_local_date_v1,
-- plus identity.has_tenant_role for the admin check.)
-- #142: a queue day cannot be closed before it ends in the branch time zone (QUE-007).
-- 1. appointment.close_queue_day_v2(tenant, branch, date, reason):
--    - a future branch-local day is rejected (unchanged);
--    - an earlier day closes as before (same as the pg_cron close_stale_queues);
--    - today (the day has not ended yet) is rejected with 22023 unless a hospital admin
--      (tenant_admin) gives a reason of 3-500 characters: an early close for an emergency closure
--      or a branch shutting early. A non-admin with a reason gets 42501.
--    Tokens expired by an early close keep the reason in queue_entries.close_reason; updated_by and
--    the row audit log record who closed it.
-- 2. appointment.close_queue_day(tenant, branch, date) keeps its signature and calls v2 without a
--    reason, so old callers can no longer close today early.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

alter table appointment.queue_entries add column if not exists close_reason text;
alter table appointment.queue_entries add constraint queue_entries_close_reason_len
  check (close_reason is null or char_length(close_reason) between 3 and 500);
comment on column appointment.queue_entries.close_reason is
  'Reason given by a hospital admin who closed the queue day early (#142). Null for normal / end-of-day closes.';

create or replace function appointment.close_queue_day_v2(p_tenant_id uuid, p_branch_id uuid, p_on date, p_reason text default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_today date;
  v_early boolean;
  v_reason text := nullif(btrim(p_reason), '');
  r record;
begin
  if p_tenant_id is null or p_branch_id is null or p_on is null then
    raise exception 'branch and date are required' using errcode = '22023';
  end if;
  if not identity.branch_exists_v1(p_tenant_id, p_branch_id) then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;
  if auth.uid() is not null then
    if p_tenant_id not in (select identity.current_tenant_ids()) then
      raise exception 'branch not found' using errcode = 'P0002';
    end if;
    if not identity.has_tenant_permission(p_tenant_id, 'queue.manage') then
      raise exception 'not permitted to close the queue' using errcode = '42501';
    end if;
    if not identity.can_access_branch(p_tenant_id, p_branch_id) then
      raise exception 'not permitted for this branch' using errcode = '42501';
    end if;
  end if;
  if v_reason is not null and char_length(v_reason) not between 3 and 500 then
    raise exception 'The reason for closing early must be 3 to 500 characters.' using errcode = '22023';
  end if;

  v_today := identity.branch_local_date_v1(p_branch_id);
  if p_on > v_today then
    raise exception 'A queue day cannot be closed before it ends in the branch time zone.' using errcode = '22023';
  end if;
  v_early := p_on = v_today;
  if v_early then
    if v_reason is null then
      raise exception 'A queue day cannot be closed before it ends in the branch time zone. Only a hospital admin can close it early, with a reason.'
        using errcode = '22023';
    end if;
    if auth.uid() is not null and not identity.has_tenant_role(p_tenant_id, array['tenant_admin']) then
      raise exception 'Only a hospital admin can close the queue before the day ends.' using errcode = '42501';
    end if;
  end if;

  perform set_config('appointment.eod_close', 'on', true);
  for r in
    select q.id, q.tenant_id, q.appointment_id
      from appointment.queue_entries q
     where q.tenant_id = p_tenant_id and q.branch_id = p_branch_id and q.queue_date = p_on
       and q.status = 'waiting' and not q.is_deleted
     for update of q
  loop
    update appointment.queue_entries set status = 'expired', cancelled_at = pg_catalog.now(),
           close_reason = case when v_early then v_reason end
     where id = r.id;
    if r.appointment_id is not null then
      update appointment.appointments set status = 'no_show'
       where tenant_id = r.tenant_id and id = r.appointment_id and status = 'checked_in';
    end if;
    v_count := v_count + 1;
  end loop;
  perform set_config('appointment.eod_close', '', true);

  return v_count;
end;
$$;

revoke all on function appointment.close_queue_day_v2(uuid, uuid, date, text) from public, anon;
grant execute on function appointment.close_queue_day_v2(uuid, uuid, date, text) to authenticated, service_role, hms_svc_scheduling;
comment on function appointment.close_queue_day_v2(uuid, uuid, date, text) is
  'Close one branch queue for a branch-local day that has ended. Today only for a hospital admin with a reason (#142). Waiting tokens expire; checked-in appointments become no_show. An early close stores the reason on the expired tokens.';

create or replace function appointment.close_queue_day(p_tenant_id uuid, p_branch_id uuid, p_on date)
returns integer
language sql
security definer
set search_path = ''
as $$
  select appointment.close_queue_day_v2(p_tenant_id, p_branch_id, p_on, null);
$$;

revoke all on function appointment.close_queue_day(uuid, uuid, date) from public, anon;
grant execute on function appointment.close_queue_day(uuid, uuid, date) to authenticated, service_role, hms_svc_scheduling;
comment on function appointment.close_queue_day(uuid, uuid, date) is
  'Compatibility wrapper for close_queue_day_v2 without a reason: closes an ended branch-local day only (#142).';
