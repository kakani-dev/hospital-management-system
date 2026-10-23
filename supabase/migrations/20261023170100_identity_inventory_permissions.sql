-- cross-schema: approved (permission names include inventory.view and the rest; this file only
-- inserts identity.role_permissions and does not read the inventory schema).
-- Inventory permissions. tenant_admin keeps the catalog, posts opening stock, and is the approver.
-- The pharmacist can look. Two-person approval is a later slice.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

insert into identity.role_permissions (role, permission) values
  ('tenant_admin', 'inventory.view'),
  ('tenant_admin', 'inventory.catalog'),
  ('tenant_admin', 'inventory.opening'),
  ('tenant_admin', 'inventory.approve'),
  ('pharmacist', 'inventory.view');
