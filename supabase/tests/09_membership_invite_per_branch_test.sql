-- PR #1 re-review nits N1 (add_member dedupes on (tenant, user, branch) only), N4 (status
-- defaults to 'invited'), N6 (no ineffective hms_api grants). Migration 20261009090000.
begin;

-- ---------- schema / grants ----------
select tests.ok(
  (select pg_get_constraintdef(oid) from pg_constraint where conname = 'memberships_tenant_user_branch_key')
    = 'UNIQUE NULLS NOT DISTINCT (tenant_id, user_id, branch_id)',
  'unique key is (tenant_id, user_id, branch_id) NULLS NOT DISTINCT: several branches per (tenant, user) are allowed');
select tests.ok(
  (select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = 'identity.memberships'::regclass and i.indisunique)
    = array['memberships_pkey', 'memberships_tenant_user_branch_key'],
  'no other unique index on memberships blocks a second branch membership');
select tests.ok(
  (select column_default from information_schema.columns
   where table_schema = 'identity' and table_name = 'memberships' and column_name = 'status') = '''invited''::text',
  'N4: memberships.status defaults to invited');
select tests.ok(
  not has_function_privilege('hms_api', 'identity.accept_membership(uuid)', 'execute')
  and not has_function_privilege('hms_api', 'identity.my_invitations()', 'execute'),
  'N6: hms_api holds no (ineffective) EXECUTE on accept_membership/my_invitations');
select tests.ok(
  has_function_privilege('authenticated', 'identity.accept_membership(uuid)', 'execute')
  and has_function_privilege('authenticated', 'identity.my_invitations()', 'execute')
  and has_function_privilege('authenticated', 'identity.add_member(uuid, text, text, uuid)', 'execute')
  and not has_function_privilege('anon', 'identity.accept_membership(uuid)', 'execute')
  and not has_function_privilege('anon', 'identity.my_invitations()', 'execute')
  and not has_function_privilege('anon', 'identity.add_member(uuid, text, text, uuid)', 'execute'),
  'N6: authenticated (the role the API switches to) can execute the invite functions; anon cannot');
select tests.ok(
  (select acl.grantee::regrole::text from pg_proc p, aclexplode(p.proacl) acl
   where p.oid = 'identity.accept_membership(uuid)'::regprocedure and acl.grantee <> p.proowner) = 'authenticated',
  'N6: accept_membership() EXECUTE is granted to authenticated only');

-- N4: an insert that omits status (trusted path) creates a consent-pending row
select tests.as_superuser();
insert into identity.memberships (tenant_id, user_id, branch_id, role)
values ('22222222-2222-4222-8222-222222222222', '0c000000-0000-4000-8000-000000000001', null, 'viewer');
select tests.ok(
  (select status from identity.memberships
   where tenant_id = '22222222-2222-4222-8222-222222222222' and user_id = '0c000000-0000-4000-8000-000000000001') = 'invited',
  'N4: a service/owner insert without status is invited, not active');
select tests.ok(
  not exists (select 1 from identity.resolve_active_context('0c000000-0000-4000-8000-000000000001')),
  'N4: that defaulted row grants no tenant context');

-- ---------- N1: second branch for an existing member ----------
select tests.authenticate_as('admin@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
create temporary table n1 (k text primary key, id uuid) on commit drop;
grant select on n1 to public;
insert into n1 values ('rec_east',
  identity.add_member('11111111-1111-4111-8111-111111111111', 'reception@alpha.example', 'nurse', 'a1111111-0000-4000-8000-000000000002'));
insert into n1 values ('rec_east_again',
  identity.add_member('11111111-1111-4111-8111-111111111111', 'reception@alpha.example', 'doctor', 'a1111111-0000-4000-8000-000000000002'));
insert into n1 values ('rec_main',
  identity.add_member('11111111-1111-4111-8111-111111111111', 'reception@alpha.example', 'nurse', 'a1111111-0000-4000-8000-000000000001'));
-- tenant-wide member (lab tech, branch NULL): a branch invite is new, a tenant-wide invite is the existing row
insert into n1 values ('lab_east',
  identity.add_member('11111111-1111-4111-8111-111111111111', 'lab@alpha.example', 'nurse', 'a1111111-0000-4000-8000-000000000002'));
insert into n1 values ('lab_null',
  identity.add_member('11111111-1111-4111-8111-111111111111', 'lab@alpha.example', 'doctor', null));
-- NULL-branch duplicates for a brand-new invitee, then a branch invite for the same person
insert into n1 values ('out_null_1', identity.add_member('11111111-1111-4111-8111-111111111111', 'outsider@example.test', 'viewer'));
insert into n1 values ('out_null_2', identity.add_member('11111111-1111-4111-8111-111111111111', 'OUTSIDER@example.test', 'nurse', null));
insert into n1 values ('out_main',
  identity.add_member('11111111-1111-4111-8111-111111111111', 'outsider@example.test', 'nurse', 'a1111111-0000-4000-8000-000000000001'));
-- branch-scoped member (consultant: doctor @ Alpha East) invited tenant-wide
insert into n1 values ('cons_null', identity.add_member('11111111-1111-4111-8111-111111111111', 'consultant@shared.example', 'doctor', null));

select tests.ok(
  (select count(*) from identity.memberships where user_id = '0a000000-0000-4000-8000-000000000002') = 1,
  'admin still sees only the receptionist''s active Main membership (the East invite is hidden)');

select tests.as_superuser();
select tests.ok(
  (select id from n1 where k = 'rec_east') is not null
  and (select status = 'invited' and role = 'nurse' from identity.memberships where id = (select id from n1 where k = 'rec_east')),
  'N1: existing member (receptionist @ Main) gets a NEW invited membership for a second branch (nurse @ East)');
select tests.ok(
  (select id from n1 where k = 'rec_east_again') = (select id from n1 where k = 'rec_east')
  and (select role from identity.memberships where id = (select id from n1 where k = 'rec_east')) = 'nurse',
  'N1: repeat invite for the same (tenant, user, branch) returns the existing id, role unchanged');
select tests.ok(
  (select id from n1 where k = 'rec_main')
    = (select id from identity.memberships where user_id = '0a000000-0000-4000-8000-000000000002'
         and branch_id = 'a1111111-0000-4000-8000-000000000001')
  and (select status = 'active' and role = 'receptionist' from identity.memberships where id = (select id from n1 where k = 'rec_main')),
  'N1: invite for a branch the member already has returns that active row unchanged (one role per branch)');
select tests.ok(
  (select count(*) from identity.memberships where user_id = '0a000000-0000-4000-8000-000000000002'
     and tenant_id = '11111111-1111-4111-8111-111111111111') = 2,
  'N1: receptionist now has exactly 2 Alpha rows (Main active, East invited)');
select tests.ok(
  (select id from n1 where k = 'lab_east') <> (select id from n1 where k = 'lab_null')
  and (select status = 'invited' and branch_id = 'a1111111-0000-4000-8000-000000000002' from identity.memberships where id = (select id from n1 where k = 'lab_east')),
  'N1: tenant-wide member gets a new invited row at a specific branch');
select tests.ok(
  (select status = 'active' and role = 'lab_technician' and branch_id is null
   from identity.memberships where id = (select id from n1 where k = 'lab_null')),
  'N1: tenant-wide (NULL branch) invite for a tenant-wide member returns the existing row unchanged');
select tests.ok(
  (select id from n1 where k = 'out_null_1') is not null
  and (select id from n1 where k = 'out_null_2') = (select id from n1 where k = 'out_null_1')
  and (select count(*) from identity.memberships where user_id = '0c000000-0000-4000-8000-000000000001'
         and tenant_id = '11111111-1111-4111-8111-111111111111' and branch_id is null) = 1,
  'N1: NULL-branch duplicates resolve to one row (IS NOT DISTINCT FROM / NULLS NOT DISTINCT)');
select tests.ok(
  (select id from n1 where k = 'out_main') not in ((select id from n1 where k = 'out_null_1'))
  and (select count(*) from identity.memberships where user_id = '0c000000-0000-4000-8000-000000000001'
         and tenant_id = '11111111-1111-4111-8111-111111111111' and status = 'invited') = 2,
  'N1: the same invitee can hold a tenant-wide and a branch invitation');
select tests.ok(
  (select status = 'invited' and branch_id is null from identity.memberships where id = (select id from n1 where k = 'cons_null'))
  and (select status from identity.memberships where user_id = '0d000000-0000-4000-8000-000000000001'
         and tenant_id = '11111111-1111-4111-8111-111111111111' and branch_id = 'a1111111-0000-4000-8000-000000000002') = 'active',
  'N1: branch-scoped member gets a new tenant-wide invitation; the branch row is untouched');

-- unchanged contract
select tests.authenticate_as('admin@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.ok(identity.add_member('11111111-1111-4111-8111-111111111111', 'nobody@nowhere.example', 'nurse', 'a1111111-0000-4000-8000-000000000002') is null,
  'no account still returns NULL');
select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$select identity.add_member('11111111-1111-4111-8111-111111111111', 'lab@alpha.example', 'nurse', 'a1111111-0000-4000-8000-000000000001')$$,
  '42501', 'non-admin still cannot invite');
select tests.as_superuser();
select tests.throws_ok(format($$update identity.memberships set status = 'active' where id = %L$$, (select id from n1 where k = 'rec_east')), '42501',
  'consent trigger still blocks activating the second-branch invite outside accept_membership');

-- ---------- the second-branch invite grants nothing until accepted, then exactly that branch ----------
select tests.authenticate_as('reception@alpha.example', '{"tenant_id": "11111111-1111-4111-8111-111111111111"}');
select tests.ok(
  (select array_agg(b) from identity.current_branch_ids('11111111-1111-4111-8111-111111111111') b) = array['a1111111-0000-4000-8000-000000000001'::uuid]
  and not identity.has_tenant_role('11111111-1111-4111-8111-111111111111', array['nurse']),
  'before accepting, the East invite adds no branch and no role');
select tests.ok(
  (select count(*) = 1 and bool_and(branch_id = 'a1111111-0000-4000-8000-000000000002' and role = 'nurse') from identity.my_invitations()),
  'the existing member sees the second-branch invitation in my_invitations()');
select identity.accept_membership((select id from n1 where k = 'rec_east'));
select tests.ok(
  (select array_agg(role || '@' || coalesce(branch_name, '*') order by role) from identity.my_memberships())
    = array['nurse@Alpha East Clinic', 'receptionist@Alpha Main Campus'],
  'after accepting: receptionist @ Main and nurse @ East');
select tests.ok(
  (select count(*) from identity.current_branch_ids('11111111-1111-4111-8111-111111111111')) = 2
  and identity.has_tenant_role('11111111-1111-4111-8111-111111111111', array['nurse']),
  'after accepting, East and the nurse role are active');
select tests.ok(
  (select tenant_id from identity.my_active_context()) = '11111111-1111-4111-8111-111111111111',
  'default tenant unchanged by the extra membership');

rollback;
