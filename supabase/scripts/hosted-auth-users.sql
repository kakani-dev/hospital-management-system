-- =============================================================================
-- HOSTED SUPABASE ONLY (never needed locally — the local shim's auth.users is minimal).
--
-- Creates the 7 SYNTHETIC demo users referenced by supabase/seed.sql directly in the
-- real auth.users table, filling the columns GoTrue expects to be non-NULL
-- (instance_id, token columns as '', app metadata). Run it BEFORE seed.sql; seed.sql's
-- own auth.users insert then hits ON CONFLICT DO NOTHING.
--
-- These users have NO password and are NOT email-confirmed, so nobody can sign in as
-- them. They exist only so memberships/user_profiles FKs resolve for RLS demos/tests.
-- To make a real demo login, set a password via the Auth admin API / dashboard instead.
-- Idempotent.
-- =============================================================================
insert into auth.users (
  instance_id, id, aud, role, email,
  raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000'::uuid, u.id::uuid, 'authenticated', 'authenticated', u.email,
  '{"provider":"email","providers":["email"]}'::jsonb, '{"synthetic":true}'::jsonb,
  '', '', '', '',
  now(), now()
from (values
  ('0a000000-0000-4000-8000-000000000001', 'admin@alpha.example'),
  ('0a000000-0000-4000-8000-000000000002', 'reception@alpha.example'),
  ('0a000000-0000-4000-8000-000000000003', 'lab@alpha.example'),
  ('0b000000-0000-4000-8000-000000000001', 'admin@beta.example'),
  ('0b000000-0000-4000-8000-000000000002', 'doctor@beta.example'),
  ('0c000000-0000-4000-8000-000000000001', 'outsider@example.test'),
  ('0d000000-0000-4000-8000-000000000001', 'consultant@shared.example')
) as u(id, email)
on conflict (id) do nothing;
