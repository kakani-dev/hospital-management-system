-- BUG-12: the last active tenant admin cannot be soft-deleted. A second admin can remove the other.
-- Synthetic users only.
begin;

select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e410000-0000-4000-8000-000000000001', 'admin2-last@alpha.example', 'authenticated', 'authenticated');
insert into identity.memberships (id, tenant_id, user_id, branch_id, role, status) values
  ('0e410000-0000-4000-8000-000000000011', '11111111-1111-4111-8111-111111111111', '0e410000-0000-4000-8000-000000000001', null, 'tenant_admin', 'active');

select tests.authenticate_as('admin2-last@alpha.example');
do $$
begin
  begin
    perform identity.soft_delete_membership('0e410000-0000-4000-8000-000000000011');
    raise exception 'self removal should fail';
  exception when sqlstate '55000' then
    if sqlerrm not like '%cannot remove your own membership%' then
      raise exception 'expected the self-removal message, got %', sqlerrm;
    end if;
  end;
end;
$$;
select tests.ok(true, 'a second admin still cannot remove their own membership');

select identity.soft_delete_membership(
  (select id from identity.memberships
    where tenant_id = '11111111-1111-4111-8111-111111111111'
      and user_id = '0a000000-0000-4000-8000-000000000001'
      and role = 'tenant_admin'));
select tests.ok(true, 'with two admins, one can remove the other');

do $$
begin
  begin
    perform identity.soft_delete_membership('0e410000-0000-4000-8000-000000000011');
    raise exception 'last admin removal should fail';
  exception when sqlstate '55000' then
    if sqlerrm not like '%last_admin%' then
      raise exception 'expected last_admin, got %', sqlerrm;
    end if;
  end;
end;
$$;
select tests.ok(true, 'the remaining admin cannot be removed');

select tests.as_superuser();
select tests.throws_ok(
  $$update identity.memberships set role = 'doctor' where id = '0e410000-0000-4000-8000-000000000011'$$,
  '55000', 'the remaining admin cannot be demoted');

rollback;
