-- #320: changing your own password records a session cutoff and revokes other
-- sessions the same way an admin reset does, so a stolen refresh token cannot
-- stay signed in. The function now returns the account email and the floored
-- cutoff epoch so the API can issue a fresh token pair after commit.
-- cross-schema: approved (updates auth.users, deletes auth.refresh_tokens and
-- auth.sessions; same surface as 20261101004000 / 20261101030000.)
set local lock_timeout = '5s';
set local statement_timeout = '120s';

drop function if exists identity.change_own_password(text);

create function identity.change_own_password(p_password text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_crypto text;
  v_hash text;
  v_email text;
  v_cutoff timestamptz;
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
   where u.id = v_user
  returning u.email into v_email;

  insert into identity.user_security as s (user_id, must_change_password, sessions_invalidated_on)
  values (v_user, false, pg_catalog.now())
  on conflict (user_id) do update
    set must_change_password = false,
        sessions_invalidated_on = pg_catalog.now()
  returning s.sessions_invalidated_on into v_cutoff;

  delete from auth.refresh_tokens t where t.user_id = v_user::text;
  delete from auth.sessions s where s.user_id = v_user;

  return jsonb_build_object(
    'email', v_email,
    'sessionsInvalidatedEpoch', pg_catalog.floor(extract(epoch from v_cutoff))::bigint
  );
end;
$$;

revoke all on function identity.change_own_password(text) from public, anon;
grant execute on function identity.change_own_password(text) to authenticated, service_role, hms_svc_identity;
