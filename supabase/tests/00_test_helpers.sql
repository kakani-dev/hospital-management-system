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

grant execute on all functions in schema tests to public;
