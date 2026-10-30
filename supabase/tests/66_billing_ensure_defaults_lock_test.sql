-- #243: ensure_defaults serialises per tenant so two first account opens cannot both insert the
-- default CONSULT price (price_list_item_no_overlap -> 409). Rolls back.
begin;
select billing.ensure_defaults('11111111-1111-4111-8111-111111111111');
select tests.ok(
  exists (select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid() and granted),
  'ensure_defaults holds a transaction-scoped advisory lock until commit');
select billing.ensure_defaults('11111111-1111-4111-8111-111111111111');
select tests.ok(
  (select count(*) from billing.price_list_item pli
     join billing.service_item si on si.id = pli.service_item_id
     join billing.price_list pl on pl.id = pli.price_list_id
   where si.tenant_id = '11111111-1111-4111-8111-111111111111' and si.code = 'CONSULT'
     and pl.branch_id is null and pl.name = 'Standard' and pli.practitioner_id is null
     and not pli.is_deleted and not si.is_deleted and not pl.is_deleted) = 1,
  'repeated ensure_defaults leaves exactly one default CONSULT price');
rollback;
