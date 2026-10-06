-- =============================================================================
-- Sprint 0 / Migration 7: fixes from the Supabase database advisors
--
-- 1. Performance advisor 0001 (unindexed_foreign_keys): the composite FK
--    identity.memberships (tenant_id, branch_id) -> identity.branches (tenant_id, id)
--    had no covering index, so deleting/updating a branch scanned memberships.
--    The new (tenant_id, branch_id) index also covers plain tenant_id lookups, which makes
--    memberships_tenant_idx redundant, so it is dropped.
-- 2. Hardening: functions are EXECUTE-able by PUBLIC by default. The audit trigger
--    functions are only ever invoked by triggers (EXECUTE is checked when the trigger is
--    created, not when it fires), so nobody needs to call them directly. This matters most
--    for audit.log_row_change(), which is SECURITY DEFINER.
-- =============================================================================

create index if not exists memberships_tenant_branch_idx on identity.memberships (tenant_id, branch_id);
drop index if exists identity.memberships_tenant_idx;

revoke all on function audit.stamp_audit_columns()   from public;
revoke all on function audit.prevent_tenant_change() from public;
revoke all on function audit.log_row_change()        from public;
revoke all on function audit.prevent_audit_mutation() from public;
