-- Hosted GoTrue generates auth.identities.email; the 20261118190000 insert listed that
-- column and raised 428C9 on POST /api/v1/platform/qa/wizard-auth-users. Recreate the
-- function so a generated email column is omitted. Fresh databases already get this
-- body from 20261118190000 after the same fix.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function identity.seed_zz_qa_wizard_auth_user(p_email text, p_password text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_email text := lower(btrim(p_email));
  v_id uuid := gen_random_uuid();
  v_crypto text;
  v_hash text;
  v_instance uuid;
begin
  if not identity.is_platform_admin() then
    raise exception 'only platform operators can seed wizard auth users' using errcode = '42501';
  end if;

  -- Tight allowlist: weekly run ids (12-digit IST stamp) or hyphenated zz-qa-wiz-<digits>.
  if v_email is null or v_email !~ '^(zz-qa\.wiz\.[0-9]{12}|zz-qa-wiz-[0-9]{8,14})@synthetic\.example$' then
    raise exception 'only tagged zz-qa wizard emails at synthetic.example may be seeded' using errcode = '42501';
  end if;

  if p_password is null or pg_catalog.length(p_password) < 10 or pg_catalog.octet_length(p_password) > 72
     or p_password !~ '[A-Za-z]' or p_password !~ '[0-9]' then
    raise exception 'weak_password: use 10-72 characters with letters and digits' using errcode = '22023';
  end if;

  if exists (select 1 from auth.users u where lower(u.email) = v_email) then
    raise exception 'wizard auth user already exists' using errcode = '23505';
  end if;

  select n.nspname into v_crypto
    from pg_catalog.pg_extension e
    join pg_catalog.pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';
  if v_crypto is null then
    raise exception 'pgcrypto is required' using errcode = '55000';
  end if;
  -- Hash only; p_password is never in a notice, exception, or audit payload.
  execute format('select %I.crypt($1, %I.gen_salt(''bf''))', v_crypto, v_crypto) into v_hash using p_password;

  insert into auth.users (id, email, aud, role, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at)
  values (v_id, v_email, 'authenticated', 'authenticated', v_hash, pg_catalog.now(),
          jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
          jsonb_build_object('synthetic', true, 'zz_qa', true, 'purpose', 'weekly_wizard'),
          pg_catalog.now());
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'auth' and table_name = 'users' and column_name = 'updated_at'
  ) then
    update auth.users u set updated_at = pg_catalog.now() where u.id = v_id;
  end if;

  if exists (
    select 1 from information_schema.columns
     where table_schema = 'auth' and table_name = 'users' and column_name = 'instance_id'
  ) then
    v_instance := coalesce(
      (select u.instance_id from auth.users u where u.instance_id is not null and u.id <> v_id limit 1),
      '00000000-0000-0000-0000-000000000000'::uuid);
    update auth.users u
       set instance_id = v_instance,
           confirmation_token = coalesce(u.confirmation_token, ''),
           recovery_token = coalesce(u.recovery_token, ''),
           email_change_token_new = coalesce(u.email_change_token_new, ''),
           email_change = coalesce(u.email_change, '')
     where u.id = v_id;
  end if;

  if to_regclass('auth.identities') is not null then
    -- Hosted GoTrue generates auth.identities.email from identity_data; inserting it raises 428C9.
    if exists (
      select 1 from information_schema.columns c
       where c.table_schema = 'auth' and c.table_name = 'identities'
         and c.column_name = 'email' and c.is_generated = 'ALWAYS'
    ) then
      insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
      values (v_id::text, v_id,
              jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true),
              'email', pg_catalog.now(), pg_catalog.now());
    else
      insert into auth.identities (provider_id, user_id, identity_data, provider, email, created_at, updated_at)
      values (v_id::text, v_id,
              jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true),
              'email', v_email, pg_catalog.now(), pg_catalog.now());
    end if;
  end if;

  insert into identity.user_profiles (id, email, display_name)
  values (v_id, v_email, 'QA Test Wizard')
  on conflict (id) do nothing;

  return v_id;
end;
$$;

revoke all on function identity.seed_zz_qa_wizard_auth_user(text, text) from public, anon;
grant execute on function identity.seed_zz_qa_wizard_auth_user(text, text) to authenticated, service_role, hms_svc_identity;
-- hms_api_login exists only on the hosted pooler, not in local CI Postgres.
do $revoke$
begin
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'hms_api_login') then
    execute 'revoke all on function identity.seed_zz_qa_wizard_auth_user(text, text) from hms_api_login';
  end if;
end
$revoke$;
