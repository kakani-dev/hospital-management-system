-- cross-schema: approved (finalize_bill reads identity.branch_bill_header_v for the branch GSTIN state, unchanged from the previous definition; read-only)
-- #109: a taxed bill must not be finalized without a known supplier state and place of supply.
-- Before this, a branch with no GSTIN produced a NULL supplier state and NULL place of supply, and
-- billing.tax_split silently treated that as intra-state (CGST + SGST). Now finalize refuses a bill that
-- has any taxed line unless both states are known. Untaxed (exempt) bills are unchanged.
-- Live data check before release: 0 finalized taxed lines had a NULL supplier state.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function billing.finalize_bill(p_tenant_id uuid, p_bill_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_bill billing.bill%rowtype;
  v_branch uuid;
  v_doc text;
  v_gstin text;
  v_legal text;
  v_state text;
  v_pos text;
  v_name text;
  v_address text;
begin
  perform billing.assert_permission(p_tenant_id, 'billing.bill');
  select * into v_bill from billing.bill where id = p_bill_id and tenant_id = p_tenant_id and not is_deleted for update;
  if v_bill.id is null then
    raise exception 'bill not found' using errcode = 'P0002';
  end if;
  select branch_id into v_branch from billing.billing_account where id = v_bill.account_id;
  perform billing.assert_branch(p_tenant_id, v_branch);
  if v_bill.status <> 'draft' then
    raise exception 'only a draft bill can be finalized' using errcode = '55000';
  end if;
  if not exists (select 1 from billing.bill_line l where l.bill_id = p_bill_id and not l.is_deleted) then
    raise exception 'a bill needs at least one line' using errcode = '22023';
  end if;
  if v_bill.reverses_bill_id is not null then
    select supplier_gstin, supplier_state_code, supplier_name, supplier_address
    into v_gstin, v_state, v_name, v_address
    from billing.bill where id = v_bill.reverses_bill_id;
    v_pos := coalesce(v_bill.pos_state_code, v_state);
  else
    select bp.gstin, bp.legal_name into v_gstin, v_legal
    from billing.branch_profile bp
    where bp.tenant_id = p_tenant_id and bp.branch_id = v_branch and not bp.is_deleted;
    select h.name, h.address into v_name, v_address
    from identity.branch_bill_header_v1(p_tenant_id, v_branch) h;
    v_name := coalesce(nullif(btrim(v_legal), ''), v_name);
    v_state := left(v_gstin, 2);
    v_pos := coalesce(v_bill.pos_state_code, v_state);
  end if;
  if (v_state is null or v_pos is null)
     and exists (select 1 from billing.bill_line l
                 where l.bill_id = p_bill_id and not l.is_deleted and coalesce(l.tax_rate_bp, 0) > 0) then
    raise exception 'place of supply is required for a taxed bill: set the branch GSTIN or the place of supply'
      using errcode = '22023';
  end if;
  v_name := nullif(btrim(left(btrim(coalesce(v_name, '')), 200)), '');
  v_address := nullif(btrim(left(btrim(coalesce(v_address, '')), 300)), '');
  v_doc := billing.assign_number(p_tenant_id, v_branch,
    case when v_bill.bill_kind = 'credit_note' then 'credit_note' else 'bill' end);
  update billing.bill set
    status = 'finalized', bill_no = v_doc, finalized_at = pg_catalog.now(), finalized_by = audit.session_actor_id(),
    supplier_gstin = v_gstin, supplier_state_code = v_state, pos_state_code = v_pos,
    supplier_name = v_name, supplier_address = v_address
  where id = p_bill_id;
  return billing.bill_json(p_bill_id);
end;
$$;

