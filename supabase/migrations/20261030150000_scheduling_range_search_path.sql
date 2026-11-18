-- #219: Supabase advisor function_search_path_mutable. The constructors Postgres made for the range type
-- appointment.timerange (and its multirange) had no fixed search_path. Pin it to empty like every other
-- function. Behaviour is unchanged: the constructors only build a range value.
-- On hosted Supabase the type (and so its constructors) is owned by supabase_admin, which the migration
-- role cannot alter (42501). Only alter constructors the current role owns; otherwise this is a no-op and
-- the advisor finding is accepted (built-in C constructors, no SQL body, no search_path risk).
set local lock_timeout = '5s';
set local statement_timeout = '120s';

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as fn
    from pg_catalog.pg_proc p
    where p.pronamespace = 'appointment'::regnamespace
      and p.proname in ('timerange', 'timemultirange')
      and pg_catalog.pg_has_role(current_user, p.proowner, 'USAGE')
  loop
    execute pg_catalog.format('alter function %s set search_path = %L', r.fn, '');
  end loop;
end;
$$;
