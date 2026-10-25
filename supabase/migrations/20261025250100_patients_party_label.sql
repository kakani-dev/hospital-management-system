-- Party name for a bill. Soft-deleted patients keep their name so a sales register stays readable.
-- Whitespace is trimmed. Blank names return null. The caller prints "Unknown".
set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- cross-schema: approved (published v1; billing earnings reads a party name and does not read patient tables)
create or replace function patient.party_label_v1(p_tenant_id uuid, p_patient_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  if p_tenant_id is null or p_patient_id is null then
    return null;
  end if;
  if (select auth.uid()) is not null
     and (p_tenant_id not in (select identity.current_tenant_ids())
          or (not identity.has_tenant_permission(p_tenant_id, 'billing.earnings')
              and not identity.has_tenant_permission(p_tenant_id, 'patients.view'))) then
    return null;
  end if;
  select nullif(pg_catalog.concat_ws(' ',
           nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p.first_name, '')), '[[:space:]]+', ' ', 'g'), ''),
           nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p.last_name, '')), '[[:space:]]+', ' ', 'g'), '')), '')
    into v_name
  from patient.patients p
  where p.tenant_id = p_tenant_id and p.id = p_patient_id;
  return v_name;
end;
$$;

comment on function patient.party_label_v1(uuid, uuid) is
  'v1 (published by patients): trimmed party name, including a soft-deleted patient. Null when unknown or the caller cannot read it.';

revoke all on function patient.party_label_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function patient.party_label_v1(uuid, uuid) to service_role, hms_svc_billing, hms_svc_patients;
