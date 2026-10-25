-- Doctor name for earnings. A soft-deleted practitioner still has historical bills, so the name stays.
set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- cross-schema: approved (published v1; billing earnings reads a practitioner name and does not read appointment tables)
create or replace function appointment.practitioner_label_v1(p_tenant_id uuid, p_practitioner_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  if p_tenant_id is null or p_practitioner_id is null then
    return null;
  end if;
  if (select auth.uid()) is not null
     and (p_tenant_id not in (select identity.current_tenant_ids())
          or (not identity.has_tenant_permission(p_tenant_id, 'billing.earnings')
              and not identity.has_tenant_permission(p_tenant_id, 'practitioners.view'))) then
    return null;
  end if;
  select nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p.display_name, '')), '[[:space:]]+', ' ', 'g'), '')
    into v_name
  from appointment.practitioners p
  where p.tenant_id = p_tenant_id and p.id = p_practitioner_id;
  return v_name;
end;
$$;

comment on function appointment.practitioner_label_v1(uuid, uuid) is
  'v1 (published by scheduling): trimmed practitioner name, including a soft-deleted practitioner. Null when unknown or the caller cannot read it.';

revoke all on function appointment.practitioner_label_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function appointment.practitioner_label_v1(uuid, uuid) to service_role, hms_svc_billing, hms_svc_scheduling;
