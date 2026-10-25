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

-- time_zone is REQUIRED (20261012090100). Branches inherit it unless they override it.
insert into identity.tenants (id, code, name, time_zone) values
  ('11111111-1111-4111-8111-111111111111', 'demo-alpha', 'Demo Alpha Hospital (synthetic)', 'Asia/Kolkata'),
  ('22222222-2222-4222-8222-222222222222', 'demo-beta',  'Demo Beta Clinic (synthetic)',    'Asia/Kolkata');

insert into identity.branches (id, tenant_id, code, name) values
  ('a1111111-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'main', 'Alpha Main Campus'),
  ('a1111111-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'east', 'Alpha East Clinic'),
  -- same branch code "main" in a different tenant is allowed (tenant-scoped uniqueness)
  ('b2222222-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'main', 'Beta Central');

-- status is explicit: the column default is 'invited' (consent required) since 20261009090000.
insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-000000000001', null,                                   'tenant_admin', 'active'),
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000001', 'receptionist', 'active'),
  ('11111111-1111-4111-8111-111111111111', '0a000000-0000-4000-8000-000000000003', null,                                   'lab_technician', 'active'),
  ('22222222-2222-4222-8222-222222222222', '0b000000-0000-4000-8000-000000000001', null,                                   'tenant_admin', 'active'),
  ('22222222-2222-4222-8222-222222222222', '0b000000-0000-4000-8000-000000000002', null,                                   'doctor', 'active'),
  ('11111111-1111-4111-8111-111111111111', '0d000000-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000002', 'doctor', 'active'),
  ('22222222-2222-4222-8222-222222222222', '0d000000-0000-4000-8000-000000000001', null,                                   'doctor', 'active');

insert into patient.patients (id, tenant_id, registered_branch_id, mrn, first_name, last_name, date_of_birth, sex, phone, email) values
  ('aa000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'ALP-0001', 'Asha',  'Synthetic-Alpha', '1985-04-12', 'female', '+1-555-0101', 'asha@patients.example'),
  ('aa000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'ALP-0002', 'Ravi',  'Synthetic-Alpha', '1972-11-03', 'male',   '+1-555-0102', null),
  ('aa000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'ALP-0003', 'Meera', 'Synthetic-Alpha', '2001-01-30', 'female', null,          null),
  ('aa000000-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'MRN-1001', 'Kiran', 'Synthetic-Alpha', '1990-06-15', 'other',  null,          null),
  ('bb000000-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'BET-0001', 'John',  'Synthetic-Beta',  '1965-09-21', 'male',   '+1-555-0201', null),
  ('bb000000-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'BET-0002', 'Grace', 'Synthetic-Beta',  '1999-12-01', 'female', null,          'grace@patients.example'),
  -- same MRN as an Alpha patient: allowed because MRN uniqueness is per tenant
  ('bb000000-0000-4000-8000-000000000003', '22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'MRN-1001', 'Kiran', 'Synthetic-Beta',  '1990-06-15', 'other',  null,          null);

-- Normalized phone numbers (patient.patient_phones, 20261019104000): the primary number of every
-- patient above, plus a separate WhatsApp number for Asha. Ravi's WhatsApp is the same as his phone.
insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary, is_whatsapp)
select p.tenant_id, p.id, patient.to_e164(p.phone, t.default_country_code), true,
       p.id = 'aa000000-0000-4000-8000-000000000002'
from patient.patients p join identity.tenants t on t.id = p.tenant_id
where p.phone is not null and patient.to_e164(p.phone, t.default_country_code) is not null;
insert into patient.patient_phones (tenant_id, patient_id, phone_e164, is_primary, is_whatsapp) values
  ('11111111-1111-4111-8111-111111111111', 'aa000000-0000-4000-8000-000000000001', '+919800000101', false, true);
update patient.patients p set phone = ph.phone_e164
from patient.patient_phones ph where ph.patient_id = p.id and ph.is_primary and not ph.is_deleted;

-- ---------------------------------------------------------------- Sprint 2 ----
-- Synthetic practitioners, weekly schedules (branch-local time) and two far-future bookings.
insert into appointment.practitioners (id, tenant_id, user_id, display_name, specialty) values
  ('c1111111-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', '0d000000-0000-4000-8000-000000000001', 'Dr. Visiting Consultant (synthetic)', 'Cardiology'),
  ('c1111111-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', null,                                   'Dr. Alpha General (synthetic)',       'General Medicine'),
  ('c2222222-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', '0b000000-0000-4000-8000-000000000002', 'Dr. Beta Doctor (synthetic)',         'Family Medicine');

insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id) values
  ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000002'),
  ('11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000001'),
  ('22222222-2222-4222-8222-222222222222', 'c2222222-0000-4000-8000-000000000001', 'b2222222-0000-4000-8000-000000000001');

insert into appointment.schedules (id, tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from) values
  ('d1111111-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000002', 1, '09:00', '13:00', 15, '2026-01-01'),
  ('d1111111-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000001', 'a1111111-0000-4000-8000-000000000002', 3, '09:00', '13:00', 15, '2026-01-01'),
  ('d1111111-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000001', 1, '10:00', '14:00', 20, '2026-01-01'),
  ('d1111111-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'c1111111-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000001', 2, '10:00', '14:00', 20, '2026-01-01'),
  ('d2222222-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'c2222222-0000-4000-8000-000000000001', 'b2222222-0000-4000-8000-000000000001', 1, '09:00', '12:00', 15, '2026-01-01');

-- 2030-01-07 is a Monday.
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason) values
  ('e1111111-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000001', 'c1111111-0000-4000-8000-000000000002',
   'aa000000-0000-4000-8000-000000000001', '2030-01-07 10:00+05:30', '2030-01-07 10:20+05:30', 'Synthetic follow-up'),
  ('e2222222-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'c2222222-0000-4000-8000-000000000001',
   'bb000000-0000-4000-8000-000000000001', '2030-01-07 09:00+05:30', '2030-01-07 09:15+05:30', 'Synthetic check-up');

-- The visiting consultant's own charts (one per hospital). A doctor sees only these.
insert into appointment.practitioners (id, tenant_id, user_id, display_name, specialty) values
  ('c2222222-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222', '0d000000-0000-4000-8000-000000000001', 'Dr. Visiting Consultant (synthetic)', 'Cardiology');
insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id) values
  ('22222222-2222-4222-8222-222222222222', 'c2222222-0000-4000-8000-000000000002', 'b2222222-0000-4000-8000-000000000001');
insert into appointment.schedules (id, tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from) values
  ('d2222222-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222', 'c2222222-0000-4000-8000-000000000002', 'b2222222-0000-4000-8000-000000000001', 1, '09:00', '12:00', 15, '2026-01-01');
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, reason) values
  ('e1111111-0000-4000-8000-000000000010', '11111111-1111-4111-8111-111111111111', 'a1111111-0000-4000-8000-000000000002', 'c1111111-0000-4000-8000-000000000001',
   'aa000000-0000-4000-8000-000000000003', '2024-01-08 09:00+05:30', '2024-01-08 09:15+05:30', 'Synthetic consultant visit'),
  ('e2222222-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001', 'c2222222-0000-4000-8000-000000000002',
   'bb000000-0000-4000-8000-000000000001', '2024-01-08 11:00+05:30', '2024-01-08 11:15+05:30', 'Synthetic consultant visit');
