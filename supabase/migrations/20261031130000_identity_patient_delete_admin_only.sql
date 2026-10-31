-- #273: only a hospital admin may delete (soft delete) a patient record. The front desk
-- (receptionist) keeps view/create/edit. Matches HmsPermissions.cs and apps/web permissions.ts.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

delete from identity.role_permissions
where role = 'receptionist' and permission = 'patients.delete';
