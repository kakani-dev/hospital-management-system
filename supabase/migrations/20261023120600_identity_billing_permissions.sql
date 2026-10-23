-- cross-schema: approved (permission names are billing.view and the rest; this file only
-- inserts identity.role_permissions and does not read the billing schema).
-- Billing permissions (ADR 0001). Names stay role.permission (one dot).
-- tenant_admin approves, reconciles and manages prices. The desk (receptionist) and the
-- billing role can raise a bill, collect and request a discount. Refunds are requested by
-- the billing role and approved by tenant_admin (mapped to the manager policy row).
set local lock_timeout = '5s';
set local statement_timeout = '30s';

insert into identity.role_permissions (role, permission) values
  ('tenant_admin', 'billing.view'),
  ('tenant_admin', 'billing.bill'),
  ('tenant_admin', 'billing.collect'),
  ('tenant_admin', 'billing.discount_request'),
  ('tenant_admin', 'billing.approve'),
  ('tenant_admin', 'billing.refund'),
  ('tenant_admin', 'billing.counter_reconcile'),
  ('tenant_admin', 'billing.pricelist_manage'),
  ('receptionist', 'billing.view'),
  ('receptionist', 'billing.bill'),
  ('receptionist', 'billing.collect'),
  ('receptionist', 'billing.discount_request'),
  ('billing', 'billing.view'),
  ('billing', 'billing.bill'),
  ('billing', 'billing.collect'),
  ('billing', 'billing.discount_request'),
  ('billing', 'billing.refund');
