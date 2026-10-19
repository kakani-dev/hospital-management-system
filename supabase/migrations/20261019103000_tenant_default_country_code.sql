-- =============================================================================
-- Level 1 (identity): identity.tenants.default_country_code, the calling code used to turn a
-- locally typed phone number (e.g. 098765 43210) into E.164 (+919876543210).
--   * Derived from the tenant time zone when not given (identity.country_code_for_zone); the
--     product default is +91.
--   * Read by other services ONLY through identity.tenant_default_country_code_v1(), which
--     returns the caller's own (active-membership) tenant value; never a client-supplied tenant.
-- =============================================================================
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function identity.country_code_for_zone(p_zone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_zone in ('Asia/Kolkata', 'Asia/Calcutta') then '+91'
    when p_zone = 'Asia/Dubai' then '+971'
    when p_zone = 'Asia/Singapore' then '+65'
    when p_zone = 'Asia/Karachi' then '+92'
    when p_zone = 'Asia/Dhaka' then '+880'
    when p_zone in ('Asia/Kathmandu', 'Asia/Katmandu') then '+977'
    when p_zone = 'Asia/Colombo' then '+94'
    when p_zone = 'Asia/Riyadh' then '+966'
    when p_zone = 'Asia/Qatar' then '+974'
    when p_zone = 'Europe/London' then '+44'
    when p_zone = 'Europe/Berlin' then '+49'
    when p_zone = 'Europe/Paris' then '+33'
    when p_zone = 'Africa/Nairobi' then '+254'
    when p_zone = 'Africa/Lagos' then '+234'
    when p_zone like 'Australia/%' then '+61'
    when p_zone in ('America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles',
                    'America/Phoenix', 'America/Anchorage', 'America/Toronto', 'America/Vancouver',
                    'Pacific/Honolulu') then '+1'
    else '+91'
  end;
$$;
revoke all on function identity.country_code_for_zone(text) from public;
grant execute on function identity.country_code_for_zone(text) to authenticated, service_role;

alter table identity.tenants add column default_country_code text;
update identity.tenants set default_country_code = identity.country_code_for_zone(time_zone);
alter table identity.tenants alter column default_country_code set not null;
alter table identity.tenants add constraint tenants_default_country_code_format
  check (default_country_code ~ '^\+[1-9][0-9]{0,2}$');
comment on column identity.tenants.default_country_code is
  'E.164 calling code (e.g. +91) applied to phone numbers typed without one. Defaults from time_zone.';

create or replace function identity.default_tenant_country_code()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.default_country_code is null then
    new.default_country_code := identity.country_code_for_zone(new.time_zone);
  end if;
  return new;
end;
$$;
revoke all on function identity.default_tenant_country_code() from public, anon, authenticated;
create trigger a_tenants_default_country_code before insert on identity.tenants
  for each row execute function identity.default_tenant_country_code();

-- the caller's own tenant only (active membership via current_tenant_ids); NULL otherwise
-- cross-schema: approved (Level 1 MRN / phone normalization; consumers: patient)
create or replace function identity.tenant_default_country_code_v1(p_tenant_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select t.default_country_code from identity.tenants t
  where t.id = p_tenant_id and t.id in (select identity.current_tenant_ids());
$$;
revoke all on function identity.tenant_default_country_code_v1(uuid) from public, anon;
grant execute on function identity.tenant_default_country_code_v1(uuid) to authenticated, service_role;

-- tenant admins may change it (tenants_update policy: tenant_admin of that tenant)
grant update (default_country_code) on identity.tenants to authenticated;
