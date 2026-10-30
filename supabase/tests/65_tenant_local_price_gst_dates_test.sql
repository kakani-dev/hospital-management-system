-- #207/#208: price selection and the first item GST row use the tenant-local date. Rolls back.
begin;
-- zone changes with future bookings are owner-confirmed; superuser is not the owner on the Supabase stack (#237)
select tests.as_owner('identity.tenants');

update identity.tenants set time_zone = 'Asia/Kolkata' where id = '11111111-1111-4111-8111-111111111111';

select tests.ok(
  billing.tenant_today('11111111-1111-4111-8111-111111111111', timestamptz '2026-10-30 19:00+00') = date '2026-10-31',
  'billing: 00:30 IST is already the next day');
select tests.ok(
  inventory.tenant_today('11111111-1111-4111-8111-111111111111', timestamptz '2026-10-30 19:00+00') = date '2026-10-31',
  'inventory: 00:30 IST is already the next day');
select tests.ok(
  billing.tenant_today('11111111-1111-4111-8111-111111111111', timestamptz '2026-10-30 18:00+00') = date '2026-10-30',
  'billing: 23:30 IST is still the same day');

update identity.tenants set time_zone = 'America/New_York' where id = '11111111-1111-4111-8111-111111111111';
select tests.ok(
  inventory.tenant_today('11111111-1111-4111-8111-111111111111', timestamptz '2026-10-31 02:00+00') = date '2026-10-30',
  'a tenant outside IST uses its own zone');
select tests.ok(
  billing.tenant_today('00000000-0000-4000-8000-00000000dead', timestamptz '2026-10-30 19:00+00') = date '2026-10-31',
  'unknown tenant falls back to Asia/Kolkata');

select tests.ok(
  (select count(*) from pg_proc p
    where p.oid in ('billing.list_service_items(uuid,text,boolean)'::regprocedure,
                    'inventory.create_item(uuid,jsonb)'::regprocedure)
      and p.prosrc ilike '%current_date%') = 0,
  'price selection and item GST no longer use the UTC current_date');

select tests.ok(
  not has_function_privilege('anon', 'billing.tenant_today(uuid,timestamptz)', 'execute')
  and not has_function_privilege('anon', 'inventory.tenant_today(uuid,timestamptz)', 'execute'),
  'anon cannot call the date helpers');

rollback;
