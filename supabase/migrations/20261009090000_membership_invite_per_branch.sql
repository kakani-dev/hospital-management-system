-- =============================================================================
-- Sprint 1 / Migration 10: PR #1 re-review nits N1, N4, N6 (follow-up to
-- 20261008090000_membership_invite_consent.sql, which is NOT edited).
--
-- N1  identity.add_member() deduplicated on (tenant, user) only, so an admin could no longer
--     give an existing member a second branch membership (e.g. billing@Main + nurse@East, the
--     per-branch model the M1 fix relies on). It now deduplicates on the membership unique key
--     (tenant_id, user_id, branch_id) with branch NULL = tenant-wide (IS NOT DISTINCT FROM):
--       * a row for exactly that (tenant, user, branch) exists (any status/role) -> return its id,
--         unchanged;
--       * otherwise -> insert a NEW 'invited' row (the consent trigger and accept flow apply).
--     Constraint check: memberships_tenant_user_branch_key is
--       UNIQUE NULLS NOT DISTINCT (tenant_id, user_id, branch_id)
--     which already allows several rows per (tenant, user) with different branches, and one
--     tenant-wide (NULL) row next to branch rows. No index or constraint change is needed. It
--     still allows only ONE role per (tenant, user, branch): inviting a second role at the same
--     branch returns the existing id (as before). Other unique indexes on the table: only the
--     primary key.
--     Concurrent duplicate invites cannot raise 23505 either: the insert uses ON CONFLICT on that
--     constraint and then returns the winner's id.
--     Unchanged contract: NULL when no account exists, tenant_admin only, new rows 'invited'.
--
-- N4  identity.memberships.status now defaults to 'invited' (was 'active'). Any insert that
--     omits status (service_role, ops SQL, seed scripts, test fixtures) now creates a
--     consent-pending row instead of a silent active membership. Trusted callers that really mean
--     an active membership must say status = 'active' explicitly. Existing rows are not touched.
--
-- N6  The EXECUTE grants on accept_membership()/my_invitations() to hms_api were no-ops: hms_api
--     is NOINHERIT, the API login (hms_api_login) is NOINHERIT too, and the API calls these
--     functions only after `set_config('role', 'authenticated', true)` plus the JWT claims
--     (RlsTransactionInterceptor), i.e. as `authenticated`, which is what auth.uid() needs.
--     Calling them as hms_api (no claims) could only ever fail (auth.uid() is null -> P0002 /
--     empty set). The grants are revoked so the ACL states the real model: authenticated only.
-- =============================================================================

-- ---------------------------------------------------------------------------- N1 ----
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

  -- Same (tenant, user, branch) already exists (any status, any role): return it unchanged.
  -- branch NULL means tenant-wide and only matches the tenant-wide row.
  select m.id into v_id
  from identity.memberships m
  where m.tenant_id = p_tenant_id
    and m.user_id = v_user
    and m.branch_id is not distinct from p_branch_id;
  if v_id is not null then
    return v_id;
  end if;

  insert into identity.user_profiles (id, email) values (v_user, v_email)
  on conflict (id) do nothing;

  insert into identity.memberships (tenant_id, user_id, branch_id, role, status)
  values (p_tenant_id, v_user, p_branch_id, p_role, 'invited')
  on conflict on constraint memberships_tenant_user_branch_key do nothing
  returning id into v_id;

  if v_id is null then -- lost a race with a concurrent identical invite
    select m.id into v_id
    from identity.memberships m
    where m.tenant_id = p_tenant_id
      and m.user_id = v_user
      and m.branch_id is not distinct from p_branch_id;
  end if;

  return v_id;
end;
$$;

comment on function identity.add_member(uuid, text, text, uuid) is
  'Tenant admin invites an existing platform user to (tenant, branch); branch NULL = tenant-wide. '
  'Creates status=invited; returns NULL if no account, the existing membership id if that exact '
  '(tenant, user, branch) row exists. Only the invitee can activate (identity.accept_membership).';

revoke all on function identity.add_member(uuid, text, text, uuid) from public, anon;
grant execute on function identity.add_member(uuid, text, text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------- N4 ----
alter table identity.memberships alter column status set default 'invited';
comment on column identity.memberships.status is
  'invited (default; only the invitee can activate via identity.accept_membership) | active | suspended. '
  'Trusted inserts that mean an active membership must set status = ''active'' explicitly.';

-- ---------------------------------------------------------------------------- N6 ----
revoke execute on function identity.accept_membership(uuid) from hms_api;
revoke execute on function identity.my_invitations() from hms_api;
comment on function identity.accept_membership(uuid) is
  'Invitee accepts a pending membership (invited -> active); else P0002. Executable by authenticated only: '
  'the API runs it after SET LOCAL ROLE authenticated + JWT claims (hms_api itself is NOINHERIT).';
comment on function identity.my_invitations() is
  'Pending invitations of auth.uid(); works without a tenant. Executable by authenticated only (see accept_membership).';
