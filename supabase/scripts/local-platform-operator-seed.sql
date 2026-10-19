-- =============================================================================
-- LOCAL / CI TEST SEED ONLY (run-sql-tests.sh). NEVER apply to a hosted project: on hosted, platform
-- operators are granted out of band with scripts/ops/grant-platform-admin.sh (APPROVED=1) for an
-- existing account. seed.sql stays operator-free (code review MIN-5) because it is also used for
-- hosted demos.
--
-- Synthetic platform-operator login standing in for Mohith (the platform operator). Uses the same
-- mechanism as hosted: identity.grant_platform_admin() -> identity.platform_admins.
-- =============================================================================
insert into auth.users (id, email, aud, role) values
  ('0e900000-0000-4000-8000-000000000001', 'operator@medicore.example', 'authenticated', 'authenticated')
on conflict (id) do nothing;
insert into identity.user_profiles (id, email, display_name) values
  ('0e900000-0000-4000-8000-000000000001', 'operator@medicore.example', 'Platform Operator (synthetic, Mohith)')
on conflict (id) do nothing;
select identity.grant_platform_admin('operator@medicore.example');
