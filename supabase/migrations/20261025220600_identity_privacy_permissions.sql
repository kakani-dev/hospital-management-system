-- cross-schema: approved (this file only inserts identity.role_permissions. It does not
-- read the privacy schema. There is no privacy_officer role: identity.memberships.role
-- is a fixed check, and these permissions map onto tenant_admin, receptionist, and doctor.)
-- DPDP permissions. tenant_admin holds every privacy permission. Reception records consent
-- and opens a request. A doctor can look. Erasure stays with tenant_admin, and executing
-- it still needs a second distinct user who also holds privacy.erase.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

insert into identity.role_permissions (role, permission) values
  ('tenant_admin', 'privacy.view'),
  ('tenant_admin', 'privacy.consent'),
  ('tenant_admin', 'privacy.notice'),
  ('tenant_admin', 'privacy.request'),
  ('tenant_admin', 'privacy.fulfil'),
  ('tenant_admin', 'privacy.erase'),
  ('receptionist', 'privacy.view'),
  ('receptionist', 'privacy.consent'),
  ('receptionist', 'privacy.request'),
  ('doctor', 'privacy.view');
