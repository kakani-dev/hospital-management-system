-- =============================================================================
-- New-tenant setup wizard (BUG-2) and branch document-prefix default (BUG-53).
--
-- Setup progress lives on identity.tenants (setup_step + setup_completed_on).
-- Clients cannot update those columns. identity.advance_setup_v1 / setup_state_v1
-- take no tenant id: they use identity.current_tenant_ids() and settings.manage.
--
-- A new branch with no billing.branch_profile gets a prefix from the hospital
-- code (uppercase, non-alphanumeric stripped, first 4 characters, else OP).
-- Existing profiles are left as they are (ON CONFLICT DO NOTHING).
--
-- identity.branches.address is the one extra column: the branch step has to
-- persist an address, and the branch form is the only writer.
--
-- cross-schema: approved (identity security-definer writes billing.branch_profile
-- for the prefix default; billing.doc_prefix_from_hospital_code is not granted
-- to client roles).
-- =============================================================================
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ---------------------------------------------------------------- setup state ----
alter table identity.tenants
  add column setup_step text,
  add column setup_completed_on timestamptz;

alter table identity.tenants disable trigger user;
update identity.tenants
   set setup_step = 'done',
       setup_completed_on = coalesce(created_on, pg_catalog.now())
 where setup_step is null;
alter table identity.tenants enable trigger user;

alter table identity.tenants
  alter column setup_step set default 'done',
  alter column setup_step set not null;

alter table identity.tenants
  add constraint tenants_setup_step_known
    check (setup_step in ('profile', 'branch', 'staff', 'schedule', 'done')),
  add constraint tenants_setup_done_has_timestamp
    check ((setup_step = 'done') = (setup_completed_on is not null));

comment on column identity.tenants.setup_step is
  'Wizard position: profile, branch, staff, schedule, or done. Existing hospitals default to done. Clients have no UPDATE grant; identity.advance_setup_v1 is the only writer.';
comment on column identity.tenants.setup_completed_on is
  'UTC timestamp set when setup_step becomes done. Null while setup is open. Consistent with setup_step (both set, or neither).';

-- Seed and any insert that omits the columns land on done. create_tenant sets profile explicitly.
create or replace function identity.default_setup_completed()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.setup_step = 'done' and new.setup_completed_on is null then
    new.setup_completed_on := pg_catalog.now();
  end if;
  return new;
end;
$$;
revoke all on function identity.default_setup_completed() from public, anon;
grant execute on function identity.default_setup_completed() to authenticated, service_role, hms_svc_identity;
create trigger b_tenants_default_setup before insert on identity.tenants
  for each row execute function identity.default_setup_completed();

-- Latest body is 20261012090100. This replacement only adds the setup columns
-- so a hospital created after this migration opens on the profile step.
create or replace function identity.create_tenant(
  p_code text,
  p_name text,
  p_time_zone text,
  p_admin_email text default null,
  p_branch_code text default 'main',
  p_branch_name text default 'Main')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_branch uuid;
  v_user uuid;
  v_email text;
begin
  if (auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon'))
     and not identity.is_platform_admin() then
    raise exception 'only platform admins can create tenants' using errcode = '42501';
  end if;
  if not identity.is_valid_time_zone(p_time_zone) then
    raise exception 'invalid_time_zone: % is not a known IANA time zone', coalesce(p_time_zone, 'null') using errcode = '22023';
  end if;

  insert into identity.tenants (code, name, time_zone, setup_step, setup_completed_on)
  values (btrim(p_code), btrim(p_name), p_time_zone, 'profile', null)
  returning id into v_tenant;

  insert into identity.branches (tenant_id, code, name, timezone_override)
  values (v_tenant, coalesce(nullif(btrim(p_branch_code), ''), 'main'), coalesce(nullif(btrim(p_branch_name), ''), 'Main'), null)
  returning id into v_branch;

  if p_admin_email is not null and length(btrim(p_admin_email)) > 0 then
    select u.id, u.email into v_user, v_email
    from auth.users u where lower(u.email) = lower(btrim(p_admin_email))
    order by u.id limit 1;
    if v_user is not null then
      insert into identity.user_profiles (id, email) values (v_user, v_email) on conflict (id) do nothing;
      insert into identity.memberships (tenant_id, user_id, branch_id, role, status)
      values (v_tenant, v_user, null, 'tenant_admin', 'invited');
    end if;
  end if;

  return v_tenant;
end;
$$;
revoke all on function identity.create_tenant(text, text, text, text, text, text) from public, anon;
grant execute on function identity.create_tenant(text, text, text, text, text, text) to authenticated, service_role;

create or replace function identity.setup_step_rank(p_step text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_step
    when 'profile' then 1
    when 'branch' then 2
    when 'staff' then 3
    when 'schedule' then 4
    when 'done' then 5
    else null
  end;
$$;
revoke all on function identity.setup_step_rank(text) from public, anon, authenticated;

-- cross-schema: approved (reads billing.branch_profile for the prefix; no client tenant id)
create or replace function identity.setup_state_v1()
returns table (step text, completed_on timestamptz, branch_id uuid, document_prefix text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_count integer;
  v_code text;
  v_step text;
  v_completed timestamptz;
  v_branch uuid;
  v_prefix text;
begin
  select count(*) into v_count from identity.current_tenant_ids();
  if v_count is distinct from 1 then
    raise exception 'setup requires exactly one active tenant' using errcode = 'P0002';
  end if;
  select t.tenant_id into v_tenant from identity.current_tenant_ids() as t(tenant_id);

  if not identity.has_tenant_permission(v_tenant, 'settings.manage') then
    raise exception 'only tenant admins can read setup' using errcode = '42501';
  end if;

  select tn.setup_step, tn.setup_completed_on, tn.code
    into v_step, v_completed, v_code
  from identity.tenants tn
  where tn.id = v_tenant and not tn.is_deleted;

  select b.id into v_branch
  from identity.branches b
  where b.tenant_id = v_tenant and not b.is_deleted
  order by (b.code = 'main') desc, b.created_on, b.id
  limit 1;

  if v_branch is not null then
    select bp.doc_prefix into v_prefix
    from billing.branch_profile bp
    where bp.tenant_id = v_tenant and bp.branch_id = v_branch and not bp.is_deleted;
  end if;
  if v_prefix is null then
    v_prefix := billing.doc_prefix_from_hospital_code(v_code);
  end if;

  step := v_step;
  completed_on := v_completed;
  branch_id := v_branch;
  document_prefix := v_prefix;
  return next;
end;
$$;
revoke all on function identity.setup_state_v1() from public, anon;
grant execute on function identity.setup_state_v1() to authenticated, service_role, hms_svc_identity;

-- cross-schema: approved (returns setup_state_v1; the tenant is the JWT's, never an argument)
create or replace function identity.advance_setup_v1(p_step text)
returns table (step text, completed_on timestamptz, branch_id uuid, document_prefix text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_count integer;
  v_current text;
  v_rank integer;
  v_target integer;
begin
  if identity.setup_step_rank(p_step) is null then
    raise exception 'unknown setup step' using errcode = '22023';
  end if;

  select count(*) into v_count from identity.current_tenant_ids();
  if v_count is distinct from 1 then
    raise exception 'setup requires exactly one active tenant' using errcode = 'P0002';
  end if;
  select t.tenant_id into v_tenant from identity.current_tenant_ids() as t(tenant_id);

  if not identity.has_tenant_permission(v_tenant, 'settings.manage') then
    raise exception 'only tenant admins can change setup' using errcode = '42501';
  end if;

  select tn.setup_step into v_current
  from identity.tenants tn
  where tn.id = v_tenant
  for update;

  if v_current = 'done' then
    if p_step = 'done' then
      return query select * from identity.setup_state_v1();
      return;
    end if;
    raise exception 'setup is already complete' using errcode = '55000';
  end if;

  v_rank := identity.setup_step_rank(v_current);
  v_target := identity.setup_step_rank(p_step);
  if v_target > v_rank + 1 then
    raise exception 'setup can only advance one step' using errcode = '22023';
  end if;

  if v_current = 'branch' and v_target > v_rank and not exists (
    select 1 from identity.branches b
    where b.tenant_id = v_tenant and not b.is_deleted and b.is_active
  ) then
    raise exception 'a live branch is required before leaving the branch step' using errcode = '55000';
  end if;

  update identity.tenants tn
     set setup_step = p_step,
         setup_completed_on = case when p_step = 'done' then pg_catalog.now() else null end
   where tn.id = v_tenant;

  return query select * from identity.setup_state_v1();
end;
$$;
revoke all on function identity.advance_setup_v1(text) from public, anon;
grant execute on function identity.advance_setup_v1(text) to authenticated, service_role, hms_svc_identity;

-- Same aggregate as tenant.created (messaging.outbox allows 'tenant'). Ids and the step only.
create or replace function identity.emit_setup_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.setup_step is not distinct from old.setup_step
     and new.setup_completed_on is not distinct from old.setup_completed_on then
    return null;
  end if;
  perform messaging.enqueue(
    new.id,
    'tenant',
    new.id,
    case when new.setup_step = 'done' and old.setup_step is distinct from 'done'
      then 'tenant.setup_completed'
      else 'tenant.setup_step_changed'
    end,
    pg_catalog.jsonb_build_object(
      'tenant_id', new.id,
      'step', new.setup_step,
      'previous_step', old.setup_step,
      'at', pg_catalog.now()));
  return null;
end;
$$;
revoke all on function identity.emit_setup_event() from public, anon, authenticated;
create trigger tenants_setup_outbox
  after update of setup_step, setup_completed_on on identity.tenants
  for each row execute function identity.emit_setup_event();

-- ---------------------------------------------------------------- branch address ----
alter table identity.branches add column address text;
alter table identity.branches add constraint branches_address_length
  check (address is null or (char_length(address) between 1 and 300 and address = btrim(address)));
comment on column identity.branches.address is
  'Optional street address (1–300 characters, trimmed). The setup wizard and the branch form write it.';

grant insert (address) on identity.branches to authenticated, hms_svc_identity;
grant update (address) on identity.branches to authenticated, hms_svc_identity;

-- ------------------------------------------------ document prefix default ----
create or replace function billing.doc_prefix_from_hospital_code(p_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    nullif(left(pg_catalog.regexp_replace(pg_catalog.upper(coalesce(p_code, '')), '[^A-Z0-9]', '', 'g'), 4), ''),
    'OP');
$$;
revoke all on function billing.doc_prefix_from_hospital_code(text) from public, anon, authenticated;

create or replace function identity.ensure_branch_doc_prefix()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  select t.code into v_code from identity.tenants t where t.id = new.tenant_id;
  insert into billing.branch_profile (tenant_id, branch_id, doc_prefix)
  values (new.tenant_id, new.id, billing.doc_prefix_from_hospital_code(v_code))
  on conflict (tenant_id, branch_id) do nothing;
  return null;
end;
$$;
revoke all on function identity.ensure_branch_doc_prefix() from public, anon;
grant execute on function identity.ensure_branch_doc_prefix() to authenticated, service_role, hms_svc_identity;

create trigger branches_default_doc_prefix
  after insert on identity.branches
  for each row execute function identity.ensure_branch_doc_prefix();

-- Branches that already exist (this migration runs before seed on a fresh database,
-- and after them on an upgraded one) get a prefix only when they have none.
insert into billing.branch_profile (tenant_id, branch_id, doc_prefix)
select b.tenant_id, b.id, billing.doc_prefix_from_hospital_code(t.code)
from identity.branches b
join identity.tenants t on t.id = b.tenant_id
on conflict (tenant_id, branch_id) do nothing;
