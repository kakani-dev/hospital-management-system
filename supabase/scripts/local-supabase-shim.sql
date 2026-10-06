-- =============================================================================
-- LOCAL / CI ONLY: minimal stand-in for the objects Supabase provides out of the box
-- (roles anon/authenticated/service_role, schema auth, auth.users, auth.uid(), auth.jwt()).
--
-- NEVER run this against a real Supabase project. It is guarded so it will not overwrite
-- existing objects, but it has no purpose there.
-- auth.uid() mirrors Supabase's implementation: it reads the "sub" claim from the
-- request.jwt.claims GUC that PostgREST sets for each request.
-- =============================================================================
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

create schema if not exists auth;

do $$
begin
  if not exists (select 1 from information_schema.tables where table_schema = 'auth' and table_name = 'users') then
    create table auth.users (
      id uuid primary key,
      email text,
      aud text default 'authenticated',
      role text default 'authenticated',
      created_at timestamptz not null default now()
    );
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'auth' and p.proname = 'uid'
  ) then
    execute $f$
      create function auth.uid() returns uuid
      language sql stable
      as $body$
        select coalesce(
          nullif(current_setting('request.jwt.claim.sub', true), ''),
          (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
        )::uuid
      $body$
    $f$;
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'auth' and p.proname = 'jwt'
  ) then
    execute $f$
      create function auth.jwt() returns jsonb
      language sql stable
      as $body$
        select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
      $body$
    $f$;
  end if;
end
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant execute on function auth.jwt() to anon, authenticated, service_role;
