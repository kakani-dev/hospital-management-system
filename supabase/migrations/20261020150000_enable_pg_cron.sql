-- Enable pg_cron (free on Supabase) and schedule the end-of-day queue close, idempotently.
-- Hosted already has both (enabled by hand on 2026-10-20 during the business-rules go-live), so there this is a no-op.
-- Environments whose Postgres has no pg_cron package (plain CI Postgres) skip it with a notice; the job is then absent
-- and appointment.close_stale_queues() can be run manually.
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron not available on this server; end-of-day no-show job not scheduled';
    return;
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    create extension pg_cron with schema pg_catalog;
  end if;
  if not exists (select 1 from cron.job where jobname = 'hms-close-stale-queues') then
    perform cron.schedule('hms-close-stale-queues', '*/15 * * * *', 'select appointment.close_stale_queues()');
  end if;
end $$;
