-- =============================================================================
-- Test helpers (installed into the throwaway test database only, never a migration).
-- Each *_test.sql file runs inside BEGIN ... ROLLBACK.
-- tests.ok() raises on failure (psql ON_ERROR_STOP aborts the run) and prints
-- "ok - <description>" as a NOTICE on success; the runner counts those lines.
-- =============================================================================
create schema if not exists tests;
grant usage on schema tests to public;

create or replace function tests.ok(p_condition boolean, p_description text)
returns void language plpgsql as $$
begin
  if p_condition is distinct from true then
    raise exception 'not ok - %', p_description;
  end if;
  raise notice 'ok - %', p_description;
end;
$$;

-- Simulates a Supabase/PostgREST request: switch to the "authenticated" role and set JWT claims.
create or replace function tests.authenticate_as(p_email text, p_extra_claims jsonb default '{}'::jsonb)
returns void language plpgsql as $$
declare
  v_id uuid;
begin
  execute 'reset role';
  select id into strict v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims',
    (jsonb_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email) || p_extra_claims)::text, true);
  execute 'set local role authenticated';
end;
$$;

create or replace function tests.as_anon()
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', jsonb_build_object('role', 'anon')::text, true);
  execute 'set local role anon';
end;
$$;

create or replace function tests.as_superuser()
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end;
$$;

-- Switches to the OWNER of p_table (what SECURITY DEFINER functions run as). On the Supabase stack
-- the tests connect as supabase_admin, a superuser that does not own the tables, and the
-- soft-delete guard (re-review R1/R2) admits only the owner. tests.as_superuser() resets it.
create or replace function tests.as_owner(p_table regclass)
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  execute format('set local role %I', (select pg_catalog.pg_get_userbyid(c.relowner) from pg_catalog.pg_class c where c.oid = p_table));
end;
$$;

-- Runs p_sql and returns the number of affected rows.
create or replace function tests.affected_rows(p_sql text)
returns bigint language plpgsql as $$
declare
  v_count bigint;
begin
  execute p_sql;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Asserts p_sql fails with SQLSTATE p_sqlstate (e.g. 42501 RLS / privilege, 23505 unique, 23503 FK).
create or replace function tests.throws_ok(p_sql text, p_sqlstate text, p_description text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_sqlstate then
      raise notice 'ok - % (got % : %)', p_description, sqlstate, sqlerrm;
      return;
    end if;
    raise exception 'not ok - % (expected %, got % : %)', p_description, p_sqlstate, sqlstate, sqlerrm;
  end;
  raise exception 'not ok - % (expected error %, statement succeeded)', p_description, p_sqlstate;
end;
$$;


-- #236: clock-relative test dates. Fixtures are written against 2030 (a Monday on 2030-01-07).
-- fwd_days() is a whole number of 52-week blocks (weekday kept) that moves 2030-01-01 to at
-- least three years ahead of the real date; it is 0 until late 2026+3y, so today's run is unchanged.
-- seed.sql applies the same shift to the seeded 2030 appointments (keep the two formulas equal).
create or replace function tests.fwd_days()
returns integer language sql stable as $$
  select greatest(0, ceil(((current_date + interval '3 years')::date - date '2030-01-01') / 364.0))::integer * 364
$$;

create or replace function tests.fwd()
returns interval language sql stable as $$ select make_interval(days => tests.fwd_days()) $$;

-- First Sunday of November (US fall back) three years ahead, and the next second Sunday of March.
create or replace function tests.us_fall_back()
returns date language sql stable as $$
  select d + ((7 - extract(dow from d)::integer) % 7)
  from (select make_date(extract(year from current_date)::integer + 3, 11, 1) as d) x
$$;

create or replace function tests.us_spring_forward()
returns date language sql stable as $$
  select d + ((7 - extract(dow from d)::integer) % 7) + 7
  from (select make_date(extract(year from tests.us_fall_back())::integer + 1, 3, 1) as d) x
$$;

grant execute on all functions in schema tests to public;
