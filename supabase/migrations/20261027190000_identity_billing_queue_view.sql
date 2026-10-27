-- Billing role: read-only OPD queue so the cashier can Collect from a token row.
-- Only queue.view is granted. Check-in, call in, done, remove and close day stay on queue.manage /
-- queue.consult_own, which the billing role does not hold. Row reads are already limited to the
-- caller's branches by queue_entries_select_branch (can_access_branch + role at that branch).
set local lock_timeout = '5s';
set local statement_timeout = '30s';

insert into identity.role_permissions (role, permission) values
  ('billing', 'queue.view')
on conflict do nothing;
