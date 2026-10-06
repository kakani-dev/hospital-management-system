-- =============================================================================
-- Sprint 1 / Migration 9: membership invite consent (PR #1 review finding B1).
--
-- Forward-only fix; 20261007090000 is NOT edited (it is already applied on the hosted
-- project). What changes:
--   1. identity.add_member() creates memberships as 'invited' (never 'active'). It returns
--      NULL when no account exists and the EXISTING membership id when the user already has
--      any membership in the tenant (no exception, no status change), so callers cannot
--      enumerate accounts.
--   2. identity.accept_membership(id): only the invitee, only 'invited' -> 'active'.
--      Anything else raises SQLSTATE P0002 (indistinguishable "not found").
--   3. identity.my_invitations(): the caller's pending invitations (works with no tenant).
--   4. Consent is enforced in the database, not only in the API:
--        * trigger identity.enforce_membership_consent():
--            - 'invited' -> anything is allowed ONLY to 'active', ONLY by the invitee, and ONLY
--              inside identity.accept_membership() (transaction-local flag bound to the row id);
--              this also stops SECURITY DEFINER / service_role / owner paths;
--            - nothing can move back into 'invited';
--            - user_id is immutable (re-pointing an existing active row at another user would
--              be the same consent bypass);
--            - a signed-in user (auth.uid() not null) can only INSERT an active/suspended row
--              for THEMSELVES; rows for anybody else must start as 'invited'.
--        * RLS: admins can only INSERT 'invited' rows and can neither see, update nor delete
--          invited rows (pending invites are hidden from admins; listing/revoking them is
--          backlog).
--   5. Invited rows are excluded from identity.is_admin_of_member() (admins do not see the
--      invitee's profile). All context/role helpers (has_tenant_role, current_tenant_ids,
--      current_branch_ids, can_access_branch, shares_tenant_with, my_memberships,
--      set_active_context, resolve_active_context) already require status = 'active'; this
--      migration keeps that invariant and the SQL tests pin it.
--   6. Default tenant resolution orders by membership age (m.created_at, m.tenant_id) instead
--      of tenant name, and the first resolved tenant is persisted to
--      user_profiles.active_tenant_id, so a later membership can never displace the default.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. add_member: invite instead of activate.
-- -----------------------------------------------------------------------------
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
  from auth.users u
  where lower(u.email) = lower(btrim(p_email))
  order by u.id
  limit 1;
  if v_user is null then
    return null; -- no account: same outcome to the caller as an invite (no enumeration)
  end if;

  -- Already a member of this tenant (any status, any branch): return it unchanged.
  select m.id into v_id
  from identity.memberships m
  where m.tenant_id = p_tenant_id and m.user_id = v_user
  order by m.created_at, m.id
  limit 1;
  if v_id is not null then
    return v_id;
  end if;

  insert into identity.user_profiles (id, email) values (v_user, v_email)
  on conflict (id) do nothing;

  insert into identity.memberships (tenant_id, user_id, branch_id, role, status)
  values (p_tenant_id, v_user, p_branch_id, p_role, 'invited')
  returning id into v_id;

  return v_id;
end;
$$;

comment on function identity.add_member(uuid, text, text, uuid) is
  'Tenant admin invites an existing platform user. Creates status=invited; returns NULL if no account, '
  'the existing membership id if already a member. Only the invitee can activate (identity.accept_membership).';

-- -----------------------------------------------------------------------------
-- 2. accept_membership: the only way out of 'invited'.
-- -----------------------------------------------------------------------------
create or replace function identity.accept_membership(p_membership_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or p_membership_id is null then
    raise exception 'invitation not found' using errcode = 'P0002';
  end if;

  -- Transaction-local, bound to this row: lets the consent trigger tell this path apart from
  -- every other UPDATE (admin RLS path, other SECURITY DEFINER functions, service_role).
  perform set_config('identity.accepting_membership', p_membership_id::text, true);

  update identity.memberships m
     set status = 'active'
   where m.id = p_membership_id
     and m.user_id = v_uid
     and m.status = 'invited'
     and exists (select 1 from identity.tenants t where t.id = m.tenant_id and t.status = 'active');

  if not found then
    perform set_config('identity.accepting_membership', '', true);
    raise exception 'invitation not found' using errcode = 'P0002';
  end if;

  perform set_config('identity.accepting_membership', '', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. my_invitations: pending invitations of the caller (no tenant context needed).
-- -----------------------------------------------------------------------------
create or replace function identity.my_invitations()
returns table (membership_id uuid, tenant_id uuid, tenant_name text, branch_id uuid, role text, invited_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select m.id, m.tenant_id, t.name, m.branch_id, m.role, m.created_at
  from identity.memberships m
  join identity.tenants t on t.id = m.tenant_id
  where m.user_id = auth.uid()
    and m.status = 'invited'
    and t.status = 'active'
  order by m.created_at, m.id
$$;

revoke all on function identity.accept_membership(uuid) from public, anon;
revoke all on function identity.my_invitations() from public, anon;
grant execute on function identity.accept_membership(uuid) to authenticated, hms_api;
grant execute on function identity.my_invitations() to authenticated, hms_api;

-- -----------------------------------------------------------------------------
-- 4a. Consent trigger (database-enforced; independent of RLS and of the caller's role).
-- -----------------------------------------------------------------------------
create or replace function identity.enforce_membership_consent()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if tg_op = 'INSERT' then
    if new.status is distinct from 'invited' and v_uid is not null and new.user_id is distinct from v_uid then
      raise exception 'memberships for other users must be created as invited (consent required)'
        using errcode = '42501';
    end if;
    return new;
  end if;

  -- UPDATE
  if new.user_id is distinct from old.user_id then
    raise exception 'membership user_id is immutable' using errcode = '42501';
  end if;

  if old.status = 'invited' and new.status is distinct from 'invited' then
    if new.status = 'active'
       and v_uid is not null
       and v_uid = old.user_id
       and coalesce(current_setting('identity.accepting_membership', true), '') = old.id::text then
      return new;
    end if;
    raise exception 'an invitation can only be accepted by the invitee (identity.accept_membership)'
      using errcode = '42501';
  end if;

  if old.status is distinct from 'invited' and new.status = 'invited' then
    raise exception 'a membership cannot be moved back to invited' using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke all on function identity.enforce_membership_consent() from public;

drop trigger if exists memberships_consent on identity.memberships;
create trigger memberships_consent before insert or update on identity.memberships
  for each row execute function identity.enforce_membership_consent();

-- -----------------------------------------------------------------------------
-- 4b/5. Membership RLS: invited rows are invisible and immutable for admins; admins may only
--       create invited rows. The invitee sees their invitations through my_invitations().
-- -----------------------------------------------------------------------------
drop policy if exists memberships_select_own_or_admin on identity.memberships;
create policy memberships_select_own_or_admin on identity.memberships
  for select to authenticated
  using (
    (user_id = (select auth.uid()) and tenant_id in (select identity.current_tenant_ids()))
    or (status <> 'invited' and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  );

drop policy if exists memberships_insert_admin on identity.memberships;
create policy memberships_insert_admin on identity.memberships
  for insert to authenticated
  with check (status = 'invited' and identity.has_tenant_role(tenant_id, array['tenant_admin']));

drop policy if exists memberships_update_admin on identity.memberships;
create policy memberships_update_admin on identity.memberships
  for update to authenticated
  using (status <> 'invited' and identity.has_tenant_role(tenant_id, array['tenant_admin']))
  with check (status <> 'invited' and identity.has_tenant_role(tenant_id, array['tenant_admin']));

drop policy if exists memberships_delete_admin on identity.memberships;
create policy memberships_delete_admin on identity.memberships
  for delete to authenticated
  using (status <> 'invited' and identity.has_tenant_role(tenant_id, array['tenant_admin']));

-- 5. Admins see profiles of active/suspended members of their tenant, never of invitees.
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
      and m.status <> 'invited'
      and identity.has_tenant_role(m.tenant_id, array['tenant_admin'])
  )
$$;

-- -----------------------------------------------------------------------------
-- 6. Default tenant: oldest active membership wins (not tenant name), persisted on first
--    resolution. VOLATILE now because it may write user_profiles; the write is best-effort
--    (wrapped in its own exception block) so the access token hook can never fail sign-in.
-- -----------------------------------------------------------------------------
create or replace function identity.resolve_active_context(p_user_id uuid)
returns table (tenant_id uuid, branch_id uuid, branch_ids uuid[], roles text[])
language plpgsql
volatile
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
  order by (m.tenant_id = v_pref_tenant) desc nulls last, m.created_at, m.tenant_id
  limit 1;

  if v_tenant is null then
    return;
  end if;

  -- Persist the first resolved default so a later membership can never displace it.
  if v_pref_tenant is null then
    begin
      insert into identity.user_profiles (id, email, active_tenant_id, active_branch_id)
      select u.id, u.email, v_tenant, null from auth.users u where u.id = p_user_id
      on conflict (id) do update
        set active_tenant_id = excluded.active_tenant_id,
            active_branch_id = null
        where identity.user_profiles.active_tenant_id is null;
    exception when others then
      raise warning 'resolve_active_context: could not persist default tenant: %', sqlerrm;
    end;
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

-- Callers of the resolver become VOLATILE too (a STABLE caller must not run a writing callee).
alter function identity.my_active_context() volatile;
alter function identity.custom_access_token_hook(jsonb) volatile;

-- Re-assert grants (create or replace keeps them; explicit for readability / drift safety).
revoke all on function identity.add_member(uuid, text, text, uuid) from public, anon;
grant execute on function identity.add_member(uuid, text, text, uuid) to authenticated, service_role;
revoke all on function identity.is_admin_of_member(uuid) from public, anon;
grant execute on function identity.is_admin_of_member(uuid) to authenticated, service_role;
