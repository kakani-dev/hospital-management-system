-- BUG-12: soft-deleting the last active tenant admin fails with the same last_admin error as
-- demotion. Checked before the self-removal guard so the last admin cannot be removed at all.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function identity.soft_delete_membership(p_membership_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m record;
begin
  select m.id, m.tenant_id, m.user_id, m.role, m.status, m.is_deleted into v_m
  from identity.memberships m where m.id = p_membership_id for update;
  -- invitations are invisible to admins (no account enumeration): treated as not found
  if v_m.id is null or v_m.tenant_id not in (select identity.current_tenant_ids())
     or v_m.is_deleted or v_m.status = 'invited' then
    raise exception 'membership not found' using errcode = 'P0002';
  end if;
  if not identity.has_tenant_role(v_m.tenant_id, array['tenant_admin']) then
    raise exception 'only tenant admins can remove members' using errcode = '42501';
  end if;
  if v_m.role = 'tenant_admin' and v_m.status = 'active'
     and not exists (
       select 1 from identity.memberships m
        where m.tenant_id = v_m.tenant_id and m.id <> v_m.id
          and m.role = 'tenant_admin' and m.status = 'active' and not m.is_deleted
     ) then
    raise exception 'last_admin: a hospital must keep at least one active admin' using errcode = '55000';
  end if;
  if v_m.user_id = auth.uid() then
    raise exception 'you cannot remove your own membership' using errcode = '55000';
  end if;
  update identity.memberships set is_deleted = true where id = v_m.id;
end;
$$;
