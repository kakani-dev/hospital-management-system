-- =============================================================================
-- SYNTHETIC SEED DATA ONLY. Every person, phone number and email below is fictional.
-- Emails use reserved .example / .test domains; phones use the fictional 555 range.
-- Two independent demo tenants (Alpha, Beta) are used by supabase/tests and the web demo.
-- =============================================================================

-- Demo auth users. Locally these go into the shim's minimal auth.users. On a hosted
-- Supabase project run supabase/scripts/hosted-auth-users.sql FIRST (it fills the extra
-- columns GoTrue needs); this insert then becomes a no-op via ON CONFLICT.
insert into auth.users (id, email, aud, role) values
  ('0a000000-0000-4000-8000-000000000001', 'admin@alpha.example',       'authenticated', 'authenticated'),
  ('0a000000-0000-4000-8000-000000000002', 'reception@alpha.example',   'authenticated', 'authenticated'),
  ('0a000000-0000-4000-8000-000000000003', 'lab@alpha.example',         'authenticated', 'authenticated'),
  ('0b000000-0000-4000-8000-000000000001', 'admin@beta.example',        'authenticated', 'authenticated'),
  ('0b000000-0000-4000-8000-000000000002', 'doctor@beta.example',       'authenticated', 'authenticated'),
  ('0c000000-0000-4000-8000-000000000001', 'outsider@example.test',     'authenticated', 'authenticated'),
  ('0d000000-0000-4000-8000-000000000001', 'consultant@shared.example', 'authenticated', 'authenticated')
on conflict (id) do nothing;

insert into identity.user_profiles (id, email, display_name) values
  ('0a000000-0000-4000-8000-000000000001', 'admin@alpha.example',       'Alpha Admin (synthetic)'),
  ('0a000000-0000-4000-8000-000000000002', 'reception@alpha.example',   'Alpha Reception (synthetic)'),
  ('0a000000-0000-4000-8000-000000000003', 'lab@alpha.example',         'Alpha Lab Tech (synthetic)'),
  ('0b000000-0000-4000-8000-000000000001', 'admin@beta.example',        'Beta Admin (synthetic)'),
  ('0b000000-0000-4000-8000-000000000002', 'doctor@beta.example',       'Beta Doctor (synthetic)'),
  ('0c000000-0000-4000-8000-000000000001', 'outsider@example.test',     'Outsider (synthetic)'),
  ('0d000000-0000-4000-8000-000000000001', 'consultant@shared.example', 'Visiting Consultant (synthetic)')
on conflict (id) do nothing;

insert into identity.tenants (id, code, name) values
  ('11111111-1111-4111-8111-111111111111', 'demo-alpha', 'Demo Alpha Hospital (synthetic)'),
  ('22222222-2222-4222-8222-222222222222', 'demo-beta',  'Demo Beta Clinic (synthetic)');

insert into identity.branches (id, tenant_id, code, name) values
  ('a1111111-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'main', 'Alpha Main Campus'),
  ('a1111111-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'east', 'Alpha East Clinic'),
  -- same branch code "main" in a different tenant is allowed (tenant-scoped uniqueness)
  ('b2222222-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'main', 'Beta Central');

insert into identity.memberships (tenant_id, user_id, branch_id, role) values
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-000000000001', null,                                   'tenant_admin'),
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000001', 'receptionist'),
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-000000000003', null,                                   'lab_technician'),
  ('22222222-2222-4222-8222-222222222222', '0b000000-0000-4000-8000-000000000001', null,                                   'tenant_admin'),
  ('22222222-2222-4222-8222-222222222222', '0b000000-0000-4000-8000-000000000002', null,                                   'doctor'),
  ('11111111-1111-4111-8111-111111111111', '0d000000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000002', 'doctor'),
  ('22222222-2222-4222-8222-222222222222', '0d000000-0000-4000-8000-000000000001', null,                                   'doctor');

insert into patient.patients (id, tenant_id, registered_branch_id, mrn, first_name, last_name, date_of_birth, sex, phone, email) values
  ('aa000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'ALP-0001', 'Asha',  'Synthetic-Alpha', '1985-04-12', 'female', '+1-555-0101', 'asha@patients.example'),
  ('aa000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'ALP-0002', 'Ravi',  'Synthetic-Alpha', '1972-11-03', 'male',   '+1-555-0102', null),
  ('aa000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'ALP-0003', 'Meera', 'Synthetic-Alpha', '2001-01-30', 'female', null,          null),
  ('aa000000-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'MRN-1001', 'Kiran', 'Synthetic-Alpha', '1990-06-15', 'other',  null,          null),
  ('bb000000-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'BET-0001', 'John',  'Synthetic-Beta',  '1965-09-21', 'male',   '+1-555-0201', null),
  ('bb000000-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'BET-0002', 'Grace', 'Synthetic-Beta',  '1999-12-01', 'female', null,          'grace@patients.example'),
  -- same MRN as an Alpha patient: allowed because MRN uniqueness is per tenant
  ('bb000000-0000-4000-8000-000000000003', '22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'MRN-1001', 'Kiran', 'Synthetic-Beta',  '1990-06-15', 'other',  null,          null);
