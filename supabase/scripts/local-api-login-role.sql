-- LOCAL / CI ONLY: login role the API uses in local dev, tests and docker-compose.
-- The password is a well-known local value; on Supabase create the login role
-- out-of-band with a real secret (see migration 20261007090000).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'hms_api_login') then
    create role hms_api_login login noinherit password 'hms_api_local_only';
  end if;
end
$$;
grant hms_api to hms_api_login;
