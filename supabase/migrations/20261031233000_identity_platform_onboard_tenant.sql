-- cross-schema: approved (platform onboarding seeds each module's per-tenant settings row once, from identity.onboarding_defaults; values stay owned and editable by each module)
-- New tenant support: one platform-admin call creates the hospital, all its branches, the first
-- admin invite and default settings seeded from config (identity.onboarding_defaults), atomically.
-- The tenant id is generated here, never taken from the client; every seeded table is tenant-RLS'd.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create table if not exists identity.onboarding_defaults (
  target text primary key check (target in (
    'billing.approval_settings', 'appointment.tenant_settings', 'appointment.reminder_settings',
    'patient.registration_settings', 'pharmacy.tenant_setting')),
  settings jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object' and not settings ? 'tenant_id'),
  updated_on timestamptz not null default now()
);
alter table identity.onboarding_defaults enable row level security;
revoke all on identity.onboarding_defaults from public, anon, authenticated;
grant select on identity.onboarding_defaults to service_role;
comment on table identity.onboarding_defaults is
  'Platform config: default settings copied into a new tenant at onboarding. Edit rows to change defaults for future tenants; existing tenants are unaffected.';

insert into identity.onboarding_defaults (target, settings) values
  ('billing.approval_settings', '{"maker_checker_threshold_paise": 20000, "cancel_refund_pct_bp": 10000, "no_show_refund_pct_bp": 0}'),
  ('appointment.tenant_settings', '{"travel_buffer_minutes": 0}'),
  ('appointment.reminder_settings', '{"enabled": false, "lead_hours": 24, "same_day_hours": 2, "min_notice_minutes": 120, "email_enabled": true, "whatsapp_enabled": false, "quiet_start": "21:00", "quiet_end": "08:00"}'),
  ('patient.registration_settings', '{"guardian_required_below_age_years": 18, "emergency_contact_required": false, "address_required": false, "referred_by_required_for_referrals": true}'),
  ('pharmacy.tenant_setting', '{"rx_validity_days": 30, "near_expiry_days": 90}')
on conflict (target) do nothing;

-- p_branches: [{"code": "main", "name": "Hyderabad Main", "address": "..."}], 1..20 entries, first is the main branch.
create or replace function identity.platform_onboard_tenant(
  p_code text, p_name text, p_time_zone text, p_admin_email text, p_branches jsonb)
returns table (tenant_id uuid, invite_link_id uuid, token text, expires_on timestamptz, branch_count int, settings_seeded int)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_link record;
  v_b jsonb;
  v_n int;
  v_first jsonb;
  v_d record;
  v_cols text;
  v_seeded int := 0;
begin
  perform identity.require_platform_admin();
  if p_admin_email is null or btrim(p_admin_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'adminEmail: a valid first-admin email is required' using errcode = '22023';
  end if;
  if p_branches is null or jsonb_typeof(p_branches) <> 'array' then
    raise exception 'branches: at least one branch is required' using errcode = '22023';
  end if;
  v_n := jsonb_array_length(p_branches);
  if v_n < 1 or v_n > 20 then
    raise exception 'branches: add 1 to 20 branches' using errcode = '22023';
  end if;
  for v_b in select * from jsonb_array_elements(p_branches) loop
    if coalesce(v_b->>'code', '') !~ '^[a-z0-9][a-z0-9-]{1,19}$' then
      raise exception 'branches: code % must be 2-20 lowercase letters, digits or hyphens', coalesce(v_b->>'code', 'null') using errcode = '22023';
    end if;
    if length(btrim(coalesce(v_b->>'name', ''))) not between 1 and 120 then
      raise exception 'branches: every branch needs a name (max 120 characters)' using errcode = '22023';
    end if;
  end loop;
  if (select count(distinct e->>'code') from jsonb_array_elements(p_branches) e) <> v_n
     or (select count(distinct lower(btrim(e->>'name'))) from jsonb_array_elements(p_branches) e) <> v_n then
    raise exception 'branches: codes and names must be unique' using errcode = '22023';
  end if;

  v_first := p_branches->0;
  v_tenant := identity.create_tenant(p_code, p_name, p_time_zone, null, v_first->>'code', btrim(v_first->>'name'));
  update identity.branches b set address = nullif(btrim(v_first->>'address'), '')
   where b.tenant_id = v_tenant and b.code = v_first->>'code';
  insert into identity.branches (tenant_id, code, name, address, timezone_override)
  select v_tenant, e->>'code', btrim(e->>'name'), nullif(btrim(e->>'address'), ''), null
    from jsonb_array_elements(p_branches) with ordinality as x(e, i) where x.i > 1;

  for v_d in select d.target, d.settings from identity.onboarding_defaults d order by d.target loop
    select string_agg(format('%I', k), ', ' order by k) into v_cols from jsonb_object_keys(v_d.settings) k;
    execute format(
      'insert into %s (tenant_id%s) select $1%s from jsonb_populate_record(null::%s, $2) r on conflict do nothing',
      v_d.target,
      case when v_cols is null then '' else ', ' || v_cols end,
      coalesce((select string_agg(format(', r.%I', k), '' order by k) from jsonb_object_keys(v_d.settings) k), ''),
      v_d.target)
    using v_tenant, v_d.settings;
    v_seeded := v_seeded + 1;
  end loop;

  select * into v_link from identity.issue_invite_link(v_tenant, p_admin_email, 'tenant_admin', null, 'platform');
  return query select v_tenant, v_link.id, v_link.token, v_link.expires_on, v_n, v_seeded;
end;
$$;
revoke all on function identity.platform_onboard_tenant(text, text, text, text, jsonb) from public, anon;
grant execute on function identity.platform_onboard_tenant(text, text, text, text, jsonb) to authenticated, hms_svc_identity;
