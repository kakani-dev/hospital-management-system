-- =============================================================================
-- Sprint 1 / Migration 8: active tenant context, custom access token hook,
-- member management functions, and a dedicated low-privilege role for the API.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Server-side "active context" per user (chosen tenant/branch). Written only through
--    identity.set_active_context(), which validates memberships. Never set by clients directly.
-- -----------------------------------------------------------------------------
alter table identity.user_profiles
  add column active_tenant_id uuid references identity.tenants (id) on delete set null,
  add column active_branch_id uuid;

alter table identity.user_profiles
  add constraint user_profiles_active_branch_same_tenant
    foreign key (active_tenant_id, active_branch_id) references identity.branches (tenant_id, id) on delete set null;

create index user_profiles_active_context_idx on identity.user_profiles (active_tenant_id, active_branch_id);

-- The hook's top-level tenant_id claim is authoritative; app_metadata.tenant_id stays as a fallback.
create or replace function identity.active_tenant_claim()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(coalesce(auth.jwt() ->> 'tenant_id', auth.jwt() -> 'app_metadata' ->> 'tenant_id'), '')::uuid
$$;

-- -----------------------------------------------------------------------------
-- 2. Internal resolver (SECURITY INVOKER, not executable by any client role).
--    Called only from SECURITY DEFINER functions below, which run as the owner.
--    Picks the stored active tenant if the membership is still valid, otherwise the
--    first active membership (by tenant name, then id) for a deterministic default.
-- -----------------------------------------------------------------------------
create or replace function identity.resolve_active_context(p_user_id uuid)
returns table (tenant_id uuid, branch_id uuid, branch_ids uuid[], roles text[])
language plpgsql
stable
set search_path = ''
as $$
declare
  v_pref_tenant uuid;
  v_pref_branch uuid;
  v_tenant uuid;
  v_branch uuid;
  v_all_branches boolean;
  v_branch_ids uuid[];
  v_roles text[];
begin
  if p_user_id is null then
    return;
  end if;

  select p.active_tenant_id, p.active_branch_id into v_pref_tenant, v_pref_branch
  from identity.user_profiles p where p.id = p_user_id;

  select m.tenant_id into v_tenant
  from identity.memberships m
  join identity.tenants t on t.id = m.tenant_id
  where m.user_id = p_user_id and m.status = 'active' and t.status = 'active'
  order by (m.tenant_id = v_pref_tenant) desc nulls last, t.name, t.id
  limit 1;

  if v_tenant is null then
    return;
  end if;

  select bool_or(m.branch_id is null) into v_all_branches
  from identity.memberships m
  where m.user_id = p_user_id and m.tenant_id = v_tenant and m.status = 'active';

  select coalesce(array_agg(b.id order by b.name, b.id), '{}') into v_branch_ids
  from identity.branches b
  where b.tenant_id = v_tenant
    and b.is_active
    and (v_all_branches or exists (
      select 1 from identity.memberships m
      where m.user_id = p_user_id and m.tenant_id = v_tenant and m.status = 'active' and m.branch_id = b.id));

  if v_tenant = v_pref_tenant and v_pref_branch = any (v_branch_ids) then
    v_branch := v_pref_branch;
  end if;

  select coalesce(array_agg(distinct m.role order by m.role), '{}') into v_roles
  from identity.memberships m
  where m.user_id = p_user_id and m.tenant_id = v_tenant and m.status = 'active'
    and (v_branch is null or m.branch_id is null or m.branch_id = v_branch);

  tenant_id := v_tenant;
  branch_id := v_branch;
  branch_ids := v_branch_ids;
  roles := v_roles;
  return next;
end;
$$;

revoke all on function identity.resolve_active_context(uuid) from public;

-- -----------------------------------------------------------------------------
-- 3. Supabase Custom Access Token Hook.
--    Enable in Dashboard > Authentication > Hooks > "Customize Access Token (JWT) Claims"
--    -> Postgres -> schema "identity" -> function "custom_access_token_hook".
--    Adds: tenant_id, branch_id (only if explicitly chosen), branch_ids, hms_roles.
--    The API and RLS never trust branch_ids/hms_roles for authorization (they re-check
--    identity.memberships); they are informational for the UI. tenant_id is intersected
--    with real memberships everywhere.
--    Failures never block sign-in: on error the token is issued without tenant claims.
-- -----------------------------------------------------------------------------
create or replace function identity.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_claims jsonb := coalesce(event -> 'claims', '{}'::jsonb);
  v_ctx record;
begin
  -- Never let a stale/forged value survive.
  v_claims := v_claims - 'tenant_id' - 'branch_id' - 'branch_ids' - 'hms_roles';

  begin
    select * into v_ctx from identity.resolve_active_context((event ->> 'user_id')::uuid);
  exception when others then
    raise warning 'custom_access_token_hook: context resolution failed: %', sqlerrm;
    return jsonb_set(event, '{claims}', v_claims);
  end;

  if v_ctx.tenant_id is not null then
    v_claims := v_claims
      || jsonb_build_object(
           'tenant_id', v_ctx.tenant_id,
           'branch_ids', to_jsonb(v_ctx.branch_ids),
           'hms_roles', to_jsonb(v_ctx.roles));
    if v_ctx.branch_id is not null then
      v_claims := v_claims || jsonb_build_object('branch_id', v_ctx.branch_id);
    end if;
  end if;

  return jsonb_set(event, '{claims}', v_claims);
end;
$$;

grant usage on schema identity to supabase_auth_admin;
grant execute on function identity.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function identity.custom_access_token_hook(jsonb) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. Functions for the signed-in user (SECURITY DEFINER; only ever about auth.uid()).
-- -----------------------------------------------------------------------------

-- Active context for the caller (used by the API when a token predates the hook).
create or replace function identity.my_active_context()
returns table (tenant_id uuid, branch_id uuid, branch_ids uuid[], roles text[])
language sql
stable
security definer
set search_path = ''
as $$
  select * from identity.resolve_active_context(auth.uid())
$$;

-- All of the caller's active memberships, regardless of the token's tenant pin
-- (drives the tenant/branch switcher).
create or replace function identity.my_memberships()
returns table (tenant_id uuid, tenant_name text, branch_id uuid, branch_name text, role text)
language sql
stable
security definer
set search_path = ''
as $$
  select m.tenant_id, t.name, m.branch_id, b.name, m.role
  from identity.memberships m
  join identity.tenants t on t.id = m.tenant_id
  left join identity.branches b on b.id = m.branch_id
  where m.user_id = auth.uid() and m.status = 'active' and t.status = 'active'
  order by t.name, b.name nulls first, m.role
$$;

-- Switch tenant/branch. Validated against memberships; the next token refresh carries it.
create or replace function identity.set_active_context(p_tenant_id uuid, p_branch_id uuid default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from identity.memberships m
    join identity.tenants t on t.id = m.tenant_id
    where m.user_id = v_uid and m.tenant_id = p_tenant_id and m.status = 'active' and t.status = 'active'
      and (p_branch_id is null or m.branch_id is null or m.branch_id = p_branch_id)
  ) then
    raise exception 'no active membership for the requested tenant/branch' using errcode = '42501';
  end if;

  if p_branch_id is not null and not exists (
    select 1 from identity.branches b where b.id = p_branch_id and b.tenant_id = p_tenant_id and b.is_active
  ) then
    raise exception 'branch does not belong to tenant' using errcode = '42501';
  end if;

  insert into identity.user_profiles (id, email, active_tenant_id, active_branch_id)
  select u.id, u.email, p_tenant_id, p_branch_id from auth.users u where u.id = v_uid
  on conflict (id) do update
    set active_tenant_id = excluded.active_tenant_id,
        active_branch_id = excluded.active_branch_id;
end;
$$;

-- Tenant admin adds an EXISTING Supabase user (by email) to their tenant.
-- (E-mail invitations for users without an account need the Auth admin API: later sprint.)
create or replace function identity.add_member(p_tenant_id uuid, p_email text, p_role text, p_branch_id uuid default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_email text;
  v_id uuid;
begin
  if not identity.has_tenant_role(p_tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can add members' using errcode = '42501';
  end if;

  select u.id, u.email into v_user, v_email
  from auth.users u where lower(u.email) = lower(btrim(p_email))
  limit 1;
  if v_user is null then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  insert into identity.user_profiles (id, email) values (v_user, v_email)
  on conflict (id) do nothing;

  insert into identity.memberships (tenant_id, user_id, branch_id, role)
  values (p_tenant_id, v_user, p_branch_id, p_role)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function identity.my_active_context() from public;
revoke all on function identity.my_memberships() from public;
revoke all on function identity.set_active_context(uuid, uuid) from public;
revoke all on function identity.add_member(uuid, text, text, uuid) from public;
grant execute on function identity.my_active_context() to authenticated, service_role;
grant execute on function identity.my_memberships() to authenticated, service_role;
grant execute on function identity.set_active_context(uuid, uuid) to authenticated, service_role;
grant execute on function identity.add_member(uuid, text, text, uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4b. Tenant admins must still see the profile (email) of SUSPENDED members of their
--     tenant, otherwise the Members page cannot show who to reactivate. Colleagues keep
--     seeing only active members (shares_tenant_with). One combined policy (no extra
--     permissive policy, keeps the performance advisor quiet).
-- -----------------------------------------------------------------------------
create or replace function identity.is_admin_of_member(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from identity.memberships m
    where m.user_id = p_user_id
      and identity.has_tenant_role(m.tenant_id, array['tenant_admin'])
  )
$$;

revoke all on function identity.is_admin_of_member(uuid) from public, anon;
grant execute on function identity.is_admin_of_member(uuid) to authenticated, service_role;

drop policy if exists user_profiles_select_self_or_colleague on identity.user_profiles;
create policy user_profiles_select_self_or_colleague on identity.user_profiles
  for select to authenticated
  using (
    id = (select auth.uid())
    or identity.shares_tenant_with(id)
    or identity.is_admin_of_member(id)
  );

-- -----------------------------------------------------------------------------
-- 5. Column grants needed by the API's EF Core writes. Audit columns are listed because
--    EF sends them; the audit triggers overwrite them, so clients still cannot forge them.
-- -----------------------------------------------------------------------------
grant insert (created_at, created_by, updated_at, updated_by, deleted_at) on patient.patients to authenticated;
grant update (updated_at, updated_by) on patient.patients to authenticated;

-- -----------------------------------------------------------------------------
-- 6. Dedicated API role. NOLOGIN + NOINHERIT: it holds NO table privileges itself.
--    The API's login role is granted hms_api, and every API transaction runs
--        SET LOCAL ROLE authenticated; set_config('request.jwt.claims', <validated claims>, true)
--    so the same RLS policies that protect PostgREST also protect API traffic.
--    A query issued outside such a transaction gets "permission denied" (fail closed).
--    Create the login role out-of-band (the password never goes in git):
--      create role hms_api_login login noinherit password '<secret>';
--      grant hms_api to hms_api_login;
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'hms_api') then
    create role hms_api nologin noinherit;
  end if;
end
$$;

grant authenticated to hms_api;
grant anon to hms_api;
comment on role hms_api is 'HMS API: no direct privileges; switches to authenticated/anon per transaction so RLS applies.';
