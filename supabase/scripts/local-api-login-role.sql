-- LOCAL / CI ONLY: login roles the API hosts use in local dev, tests and docker-compose.
-- The passwords are well-known local values; on Supabase create the login roles
-- out-of-band with real secrets (see migrations 20261007090000 and 20261011090100; group roles hms_svc_*).
do $$
begin
  -- App Service medicore-hms-api still logs in as this role until the cutover runbook.
  if not exists (select 1 from pg_roles where rolname = 'hms_api_login') then
    create role hms_api_login login noinherit password 'hms_api_local_only';
  end if;
  -- One login per microservice (identity / patients / scheduling).
  if not exists (select 1 from pg_roles where rolname = 'hms_identity_login') then
    create role hms_identity_login login noinherit password 'hms_identity_local_only';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'hms_patients_login') then
    create role hms_patients_login login noinherit password 'hms_patients_local_only';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'hms_scheduling_login') then
    create role hms_scheduling_login login noinherit password 'hms_scheduling_local_only';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'hms_billing_login') then
    create role hms_billing_login login noinherit password 'hms_billing_local_only';
  end if;
end
$$;
grant hms_api to hms_api_login;
grant hms_svc_identity to hms_identity_login;
grant hms_svc_patients to hms_patients_login;
grant hms_svc_scheduling to hms_scheduling_login;
grant hms_svc_billing to hms_billing_login;
