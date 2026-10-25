-- BUG-11: an operator can close one branch's queue for a branch-local day.
-- cross-schema: approved (branch zone and permission live in identity)
-- Waiting tokens become expired. A checked-in appointment on that token becomes no_show through
-- the existing end-of-day flag. The branch zone (tenant zone unless the branch overrides it)
-- decides which calendar day is "today"; a future day is rejected. The cron close uses the same
-- expired state for waiting tokens left over from an earlier day.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

alter table appointment.queue_entries drop constraint queue_entries_status_valid;
alter table appointment.queue_entries add constraint queue_entries_status_valid
  check (status in ('waiting', 'in_consultation', 'done', 'cancelled', 'no_show', 'expired'));

create or replace function appointment.close_stale_queues()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  r record;
begin
  perform set_config('appointment.eod_close', 'on', true);
  for r in
    select q.id, q.tenant_id, q.appointment_id
      from appointment.queue_entries q
     where q.status = 'waiting' and not q.is_deleted
       and q.queue_date < identity.branch_local_date_v1(q.branch_id)
     for update of q skip locked
  loop
    update appointment.queue_entries set status = 'expired', cancelled_at = pg_catalog.now() where id = r.id;
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

comment on function appointment.close_stale_queues() is
  'End-of-day close: queue entries still waiting on an earlier branch-local day become expired. pg_cron, every 15 min.';

create or replace function appointment.close_queue_day(p_tenant_id uuid, p_branch_id uuid, p_on date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
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
  if p_on > identity.branch_local_date_v1(p_branch_id) then
    raise exception 'A queue day cannot be closed before it ends in the branch time zone.' using errcode = '22023';
  end if;

  perform set_config('appointment.eod_close', 'on', true);
  for r in
    select q.id, q.tenant_id, q.appointment_id
      from appointment.queue_entries q
     where q.tenant_id = p_tenant_id and q.branch_id = p_branch_id and q.queue_date = p_on
       and q.status = 'waiting' and not q.is_deleted
     for update of q
  loop
    update appointment.queue_entries set status = 'expired', cancelled_at = pg_catalog.now() where id = r.id;
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

revoke all on function appointment.close_queue_day(uuid, uuid, date) from public, anon;
grant execute on function appointment.close_queue_day(uuid, uuid, date) to authenticated, service_role, hms_svc_scheduling;

comment on function appointment.close_queue_day(uuid, uuid, date) is
  'Close one branch queue for a branch-local day (not a future day). Waiting tokens become expired; checked-in appointments become no_show.';
