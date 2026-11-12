-- #219: range constructors have a fixed search_path (20261030150000_scheduling_range_search_path). Rolls back.
begin;

select tests.ok(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'appointment' and p.proname in ('timerange', 'timemultirange')
      and pg_has_role(current_user, p.proowner, 'USAGE')
      and not coalesce(p.proconfig @> array['search_path=""'], false)) = 0
  and (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'appointment' and p.proname in ('timerange', 'timemultirange')) = 5,
  'every owned appointment range constructor pins search_path to empty');

select tests.ok(
  appointment.timemultirange(appointment.timerange('09:00', '10:00'))::text = '{[09:00:00,10:00:00)}',
  'the constructors still build ranges');

rollback;
