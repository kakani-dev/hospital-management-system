## Summary

## Checklist
- [ ] Conventional commit title (`feat:`, `fix:`, `chore:`, `docs:`, `test:`, ...)
- [ ] Tenant-owned tables have `tenant_id`, RLS policies and SQL isolation tests
- [ ] No tenant id is accepted from the client; tenant comes from validated claims + membership
- [ ] Only synthetic data in seeds, fixtures and screenshots
- [ ] Tests added/updated; CI green
