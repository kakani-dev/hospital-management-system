-- cross-schema: approved (service-role grants, RLS policy roles, and published _v1 EXECUTE;
-- reviewed with ADR 0002. Does not revoke authenticated's own grants, so the legacy host keeps working.)
-- Database per service on the shared cluster (ADR 0002).
--
-- Each hms_svc_* group role receives the same table, column, sequence and function privileges
-- `authenticated` has on THAT service's schema, and is added to that schema's RLS policies.
-- It is then removed from `authenticated`, so SET ROLE authenticated fails and the service
-- cannot read another schema's tables. Cross-schema reads are EXECUTE on the approved
-- functions listed below (RLS helpers, tenant resolution, and published _v1 contracts).
--
-- Login roles and passwords stay out of band (supabase/scripts/local-api-login-role.sql and
-- docs/runbooks/monolith-cutover.md). hms_api / hms_api_login are unchanged.
-- anon membership stays, so public identity routes can still SET ROLE anon.
--
-- Apply this only together with service images that set Database:SessionRole (see the runbook).
-- An older image that SET ROLE authenticated will fail once authenticated is revoked here.

set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ---------------------------------------------------------------- own-schema grants + policies ----
do $$
declare
  v_schema text;
  v_role text;
  r record;
begin
  for v_schema, v_role in
    select * from (values
      ('identity', 'hms_svc_identity'),
      ('patient', 'hms_svc_patients'),
      ('appointment', 'hms_svc_scheduling')
    ) as t(schema_name, role_name)
  loop
    execute format('grant usage on schema %I to %I', v_schema, v_role);

    -- pg_catalog, not information_schema: the information_schema views hide grants
    -- unless the current role is the grantor, the grantee, or a superuser that
    -- pg_has_role treats as a member. Catalog ACLs are what the migration role sees.
    for r in
      select n.nspname as table_schema, c.relname as table_name, x.privilege_type
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      cross join lateral aclexplode(c.relacl) x
      join pg_roles gr on gr.oid = x.grantee
      where n.nspname = v_schema
        and c.relkind in ('r', 'p', 'v', 'm')
        and gr.rolname = 'authenticated'
        and x.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER')
    loop
      execute format(
        'grant %s on table %I.%I to %I',
        r.privilege_type, r.table_schema, r.table_name, v_role);
    end loop;

    for r in
      select n.nspname as table_schema, c.relname as table_name, x.privilege_type,
             string_agg(quote_ident(att.attname), ', ' order by att.attname) as cols
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute att on att.attrelid = c.oid and att.attnum > 0 and not att.attisdropped
      cross join lateral aclexplode(att.attacl) x
      join pg_roles gr on gr.oid = x.grantee
      where n.nspname = v_schema
        and c.relkind in ('r', 'p', 'v', 'm')
        and gr.rolname = 'authenticated'
        and x.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
      group by n.nspname, c.relname, x.privilege_type
    loop
      execute format(
        'grant %s (%s) on table %I.%I to %I',
        r.privilege_type, r.cols, r.table_schema, r.table_name, v_role);
    end loop;

    for r in
      select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = v_schema
        and has_function_privilege('authenticated', p.oid, 'execute')
    loop
      execute format('grant execute on function %s to %I', r.sig, v_role);
    end loop;

    -- has_sequence_privilege() errors on a non-sequence. Keep it out of the SELECT:
    -- the planner may call a WHERE function before the relkind filter.
    for r in
      select n.nspname, c.relname, c.oid
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = v_schema
        and c.relkind = 'S'
    loop
      if has_sequence_privilege('authenticated', r.oid, 'usage') then
        execute format('grant usage, select on sequence %I.%I to %I', r.nspname, r.relname, v_role);
      end if;
    end loop;

    for r in
      select n.nspname as schema_name, c.relname, pol.polname,
             (
               select string_agg(quote_ident(rr.rolname), ', ' order by rr.rolname)
               from pg_roles rr
               where rr.oid = any (pol.polroles)
             ) as roles
      from pg_policy pol
      join pg_class c on c.oid = pol.polrelid
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = v_schema
        and not (0 = any (pol.polroles))
        and not exists (
          select 1 from pg_roles rr
          where rr.oid = any (pol.polroles) and rr.rolname = v_role)
    loop
      if r.roles is null then
        continue;
      end if;
      execute format(
        'alter policy %I on %I.%I to %s, %I',
        r.polname, r.schema_name, r.relname, r.roles, v_role);
    end loop;
  end loop;
end
$$;

-- -------------------------------- approved cross-schema EXECUTE (not table grants) ----
-- USAGE on a schema lets the role resolve a function. It does not grant table privileges.
-- Every service calls identity helpers. Patients calls one appointment function.
-- Scheduling calls one patient function. auth.uid() is called from RLS policies.
grant usage on schema auth to hms_svc_identity, hms_svc_patients, hms_svc_scheduling;
grant usage on schema identity to hms_svc_patients, hms_svc_scheduling;
grant usage on schema patient to hms_svc_scheduling;
grant usage on schema appointment to hms_svc_patients;

-- RLS helpers and tenant resolution. Every service calls these; they are SECURITY DEFINER
-- and do not grant table access. auth.uid() is required because hosted Supabase revokes it from PUBLIC.
grant execute on function auth.uid() to hms_svc_identity, hms_svc_patients, hms_svc_scheduling;

do $$
begin
  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'auth' and p.proname = 'jwt'
  ) then
    grant execute on function auth.jwt() to hms_svc_identity, hms_svc_patients, hms_svc_scheduling;
  end if;
end
$$;

grant execute on function identity.current_tenant_ids() to hms_svc_identity, hms_svc_patients, hms_svc_scheduling;
grant execute on function identity.has_tenant_role(uuid, text[]) to hms_svc_identity, hms_svc_patients, hms_svc_scheduling;
grant execute on function identity.has_tenant_permission(uuid, text) to hms_svc_identity, hms_svc_patients, hms_svc_scheduling;
grant execute on function identity.can_access_branch(uuid, uuid) to hms_svc_identity, hms_svc_patients, hms_svc_scheduling;
grant execute on function identity.my_tenant_grant_v1(uuid) to hms_svc_identity, hms_svc_patients, hms_svc_scheduling;
grant execute on function identity.my_active_context() to hms_svc_identity, hms_svc_patients, hms_svc_scheduling;

-- patients reads scheduling/identity only through these contracts (and BranchScope).
grant execute on function identity.tenant_default_country_code_v1(uuid) to hms_svc_patients;
grant execute on function identity.branch_exists_v1(uuid, uuid) to hms_svc_patients, hms_svc_scheduling, authenticated;
grant execute on function appointment.patient_last_booked_v1(uuid, integer) to hms_svc_patients;

-- scheduling embeds patient names only through the published summary.
grant execute on function patient.patient_summary_v1(uuid, uuid[]) to hms_svc_scheduling;

-- ---------------------------------------------------------------- fail closed ----
revoke authenticated from hms_svc_identity;
revoke authenticated from hms_svc_patients;
revoke authenticated from hms_svc_scheduling;

comment on role hms_svc_identity is
  'Identity service session role. Grants on schema identity only, plus approved _v1 / RLS-helper EXECUTE. Not a member of authenticated.';
comment on role hms_svc_patients is
  'Patients service session role. Grants on schema patient only, plus approved _v1 / RLS-helper EXECUTE. Not a member of authenticated.';
comment on role hms_svc_scheduling is
  'Scheduling service session role. Grants on schema appointment only, plus approved _v1 / RLS-helper EXECUTE and hms_dispatcher for its outbox. Not a member of authenticated.';
