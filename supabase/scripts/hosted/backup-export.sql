-- READ-ONLY logical export of every row in the app schemas, as ONE json document (run as postgres via
-- Supabase MCP execute_sql; save the result verbatim to /workspace/deploy-evidence/backup-<ts>/data.json).
-- Synthetic data only. Volumes are tiny (tens of rows). Restore = re-insert from this JSON (see runbook §6).
select jsonb_build_object(
  'taken_at', now(),
  'history', (select jsonb_agg(version order by version) from supabase_migrations.schema_migrations),
  'identity.tenants',       (select coalesce(jsonb_agg(to_jsonb(t) order by t.id), '[]') from identity.tenants t),
  'identity.branches',      (select coalesce(jsonb_agg(to_jsonb(t) order by t.id), '[]') from identity.branches t),
  'identity.user_profiles', (select coalesce(jsonb_agg(to_jsonb(t) order by t.id), '[]') from identity.user_profiles t),
  'identity.memberships',   (select coalesce(jsonb_agg(to_jsonb(t) order by t.id), '[]') from identity.memberships t),
  'patient.patients',       (select coalesce(jsonb_agg(to_jsonb(t) order by t.id), '[]') from patient.patients t),
  'audit.audit_log',        (select coalesce(jsonb_agg(to_jsonb(t) order by t.id), '[]') from audit.audit_log t)
) as backup;
