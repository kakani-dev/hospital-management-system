-- cross-schema: approved (creates pg_cron in pg_catalog and writes cron.job; the command only calls appointment.close_stale_queues())
-- Enable pg_cron (free on Supabase) and schedule the end-of-day queue close, idempotently.
-- Hosted already has pg_cron 1.6.4 and this exact job (enabled by hand on 2026-10-20 during the
-- business-rules go-live). When cron.job already has hms-close-stale-queues at */15 * * * * running
-- `select appointment.close_stale_queues()`, nothing is written: cron.schedule(name, ...) upserts in
-- pg_cron 1.6.4 (INSERT ... ON CONFLICT DO UPDATE), which would rewrite the row even when the values
-- match, so it is called only when the stored schedule or command differs.
-- Plain CI Postgres has no pg_cron package and skips with a notice. If the package is present but
-- pg_cron is not in shared_preload_libraries, CREATE EXTENSION fails, so that skips with a notice too
-- and appointment.close_stale_queues() can be run manually.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron not available on this server; end-of-day no-show job not scheduled';
    return;
  end if;

  if not exists (
    select 1
      from unnest(string_to_array(current_setting('shared_preload_libraries'), ',')) as lib(entry)
     where btrim(entry) = 'pg_cron'
  ) then
    raise notice 'pg_cron is not in shared_preload_libraries; end-of-day no-show job not scheduled';
    return;
  end if;

  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    create extension pg_cron with schema pg_catalog;
  end if;

  if not exists (
    select 1
      from cron.job
     where jobname = 'hms-close-stale-queues'
       and schedule = '*/15 * * * *'
       and command = 'select appointment.close_stale_queues()'
  ) then
    perform cron.schedule(
      'hms-close-stale-queues',
      '*/15 * * * *',
      'select appointment.close_stale_queues()');
  end if;
end $$;
