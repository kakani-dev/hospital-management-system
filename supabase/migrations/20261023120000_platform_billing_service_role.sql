-- cross-schema: approved (creates hms_svc_billing only; no table grants. Login hms_billing_login
-- stays out of band, same as hms_scheduling_login. ADR 0002.)
-- Billing service group role. NOLOGIN NOINHERIT. Member of anon so the host can SET ROLE anon
-- for the public receipt and webhook routes. Not a member of authenticated, hms_dispatcher,
-- or hms_mailer.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $$
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'hms_svc_billing') then
    create role hms_svc_billing nologin noinherit;
  end if;
end
$$;

grant anon to hms_svc_billing;
revoke authenticated from hms_svc_billing;

comment on role hms_svc_billing is
  'Billing service session role (Database:SessionRole). Owns no tables. Reads other services only through published _v1 functions.';
