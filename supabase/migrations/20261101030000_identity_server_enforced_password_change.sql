-- cross-schema: approved (password-change enforcement reads/writes auth.users and auth.sessions; same as 20261101004000)
-- Security fix: the must-change-password flag is server-owned, and access tokens issued before a reset stop working.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create table if not exists identity.user_security (
  user_id uuid primary key references auth.users (id) on delete cascade,
  must_change_password boolean not null default false,
  sessions_invalidated_on timestamptz
);
alter table identity.user_security enable row level security;
revoke all on identity.user_security from public, anon, authenticated;
grant select, insert, update, delete on identity.user_security to service_role;

create or replace function identity.admin_set_member_password(p_tenant_id uuid, p_membership_id uuid, p_password text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_m identity.memberships%rowtype;
  v_email text;
  v_id uuid := gen_random_uuid();
  v_crypto text;
  v_hash text;
begin
  if v_actor is null or p_tenant_id is null
     or p_tenant_id not in (select identity.current_tenant_ids())
     or not identity.has_tenant_role(p_tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can reset passwords' using errcode = '42501';
  end if;

  -- Policy (same as the web form): 10-72 characters with at least one letter and one digit.
  if p_password is null or pg_catalog.length(p_password) < 10 or pg_catalog.octet_length(p_password) > 72
     or p_password !~ '[A-Za-z]' or p_password !~ '[0-9]' then
    raise exception 'weak_password: use 10-72 characters with letters and digits' using errcode = '22023';
  end if;

  select m.* into v_m from identity.memberships m where m.id = p_membership_id;
  if v_m.id is null or v_m.is_deleted or v_m.status = 'invited' or v_m.user_id is null then
    raise exception 'membership not found' using errcode = 'P0002';
  end if;
  if v_m.tenant_id <> p_tenant_id then
    raise exception 'member belongs to another hospital' using errcode = '42501';
  end if;
  if v_m.user_id = v_actor then
    raise exception 'self_reset: use your own account settings to change your password' using errcode = '55000';
  end if;
  if exists (select 1 from identity.platform_admins pa where pa.user_id = v_m.user_id and not pa.is_deleted) then
    raise exception 'platform admins cannot be reset by a hospital admin' using errcode = '42501';
  end if;

  if (select count(*) from identity.password_resets r
       where r.user_id = v_m.user_id and r.created_on > pg_catalog.now() - interval '1 hour') >= 3
     or (select count(*) from identity.password_resets r
          where r.created_by = v_actor and r.created_on > pg_catalog.now() - interval '1 hour') >= 20 then
    raise exception 'too many password resets' using errcode = '54000';
  end if;

  select u.email into v_email from auth.users u where u.id = v_m.user_id for update;
  if v_email is null then
    raise exception 'membership not found' using errcode = 'P0002';
  end if;

  -- Older emailed links stop working; this row also counts toward the rate limit.
  update identity.password_resets r set consumed_on = pg_catalog.now()
   where r.user_id = v_m.user_id and r.consumed_on is null and not r.is_deleted;
  insert into identity.password_resets (id, tenant_id, membership_id, user_id, token_hash, expires_on, consumed_on)
  values (v_id, p_tenant_id, v_m.id, v_m.user_id,
          identity.invite_token_hash(pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(gen_random_uuid()::text || gen_random_uuid()::text, 'UTF8')), 'hex')),
          pg_catalog.now(), pg_catalog.now());

  select n.nspname into v_crypto
    from pg_catalog.pg_extension e join pg_catalog.pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';
  if v_crypto is null then
    raise exception 'pgcrypto is required' using errcode = '55000';
  end if;
  execute format('select %I.crypt($1, %I.gen_salt(''bf''))', v_crypto, v_crypto) into v_hash using p_password;
  -- needs_password: the web app makes them choose their own password right after they sign in.
  -- The flag lives in app metadata (users cannot write it) and in identity.user_security, which the API checks.
  update auth.users u
     set encrypted_password = v_hash,
         raw_app_meta_data = coalesce(u.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('must_change_password', true),
         raw_user_meta_data = coalesce(u.raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('needs_password', true)
   where u.id = v_m.user_id;
  insert into identity.user_security as s (user_id, must_change_password, sessions_invalidated_on)
  values (v_m.user_id, true, pg_catalog.now())
  on conflict (user_id) do update set must_change_password = true, sessions_invalidated_on = pg_catalog.now();

  delete from auth.refresh_tokens t where t.user_id = v_m.user_id::text;
  delete from auth.sessions s where s.user_id = v_m.user_id;

  -- Who set whose password, and when. Never the password.
  perform audit.record_admin_event(p_tenant_id, 'identity', 'password_resets', v_id,
    jsonb_build_object('event', 'admin_password_set', 'target_user_id', v_m.user_id, 'membership_id', v_m.id),
    v_actor);
end;
$$;

revoke all on function identity.admin_set_member_password(uuid, uuid, text) from public, anon;
grant execute on function identity.admin_set_member_password(uuid, uuid, text) to authenticated, service_role, hms_svc_identity;

-- The API asks this on every request for the signed-in user: must they change their password, and
-- are tokens issued before sessions_invalidated_on (epoch seconds) revoked?
create or replace function identity.my_password_state()
returns table (must_change_password boolean, sessions_invalidated_epoch bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(s.must_change_password, false),
         pg_catalog.floor(extract(epoch from s.sessions_invalidated_on))::bigint
    from (select auth.uid() as uid) me
    left join identity.user_security s on s.user_id = me.uid
   where me.uid is not null;
$$;
revoke all on function identity.my_password_state() from public, anon;
grant execute on function identity.my_password_state() to authenticated, service_role, hms_svc_identity;

-- The only way to clear the flag: the signed-in user sets a new password that meets the policy.
create or replace function identity.change_own_password(p_password text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_crypto text;
  v_hash text;
begin
  if v_user is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_password is null or pg_catalog.length(p_password) < 10 or pg_catalog.octet_length(p_password) > 72
     or p_password !~ '[A-Za-z]' or p_password !~ '[0-9]' then
    raise exception 'weak_password: use 10-72 characters with letters and digits' using errcode = '22023';
  end if;
  select n.nspname into v_crypto
    from pg_catalog.pg_extension e join pg_catalog.pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';
  if v_crypto is null then
    raise exception 'pgcrypto is required' using errcode = '55000';
  end if;
  execute format('select %I.crypt($1, %I.gen_salt(''bf''))', v_crypto, v_crypto) into v_hash using p_password;
  update auth.users u
     set encrypted_password = v_hash,
         raw_app_meta_data = coalesce(u.raw_app_meta_data, '{}'::jsonb) - 'must_change_password',
         raw_user_meta_data = coalesce(u.raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('needs_password', false)
   where u.id = v_user;
  update identity.user_security s set must_change_password = false where s.user_id = v_user;
end;
$$;
revoke all on function identity.change_own_password(text) from public, anon;
grant execute on function identity.change_own_password(text) to authenticated, service_role, hms_svc_identity;
