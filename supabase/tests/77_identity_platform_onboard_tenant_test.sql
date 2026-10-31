-- New tenant support: identity.platform_onboard_tenant (migration 20261031233000).
-- Self-contained synthetic operator; checks atomic creation, config-seeded defaults and tenant isolation.
begin;

select tests.as_superuser();
insert into auth.users (id, email, role, aud) values
  ('0e770000-0000-4000-8000-000000000001', 'op-77@medicore.example', 'authenticated', 'authenticated'),
  ('0e770000-0000-4000-8000-000000000002', 'zz-qa-admin@onboard77.example', 'authenticated', 'authenticated');
select identity.grant_platform_admin('op-77@medicore.example');
update identity.onboarding_defaults set settings = settings || '{"rx_validity_days": 45}' where target = 'pharmacy.tenant_setting';

select tests.ok(not has_function_privilege('anon', 'identity.platform_onboard_tenant(text,text,text,text,jsonb)', 'execute')
  and not has_table_privilege('authenticated', 'identity.onboarding_defaults', 'select'),
  'onboarding is not reachable anonymously and its config is not readable by clients');
select tests.ok((select count(*) = 0 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
  where c.relkind in ('r', 'p') and not c.relrowsecurity and n.nspname not in ('pg_catalog', 'information_schema', 'tests')),
  'guardrail: every table with a tenant_id has row level security enabled');

select tests.authenticate_as('admin@alpha.example');
select tests.throws_ok($$select * from identity.platform_onboard_tenant('zz-evil', 'Evil (synthetic)', 'Asia/Kolkata', 'x@evil.example', '[{"code":"main","name":"Main"}]')$$,
  '42501', 'a tenant admin cannot onboard tenants');

select tests.authenticate_as('op-77@medicore.example');
select tests.throws_ok($$select * from identity.platform_onboard_tenant('zz-dup', 'Dup (synthetic)', 'Asia/Kolkata', 'a@dup.example', '[{"code":"main","name":"A"},{"code":"main","name":"B"}]')$$,
  '22023', 'duplicate branch codes are rejected');
select tests.throws_ok($$select * from identity.platform_onboard_tenant('zz-none', 'None (synthetic)', 'Asia/Kolkata', 'a@none.example', '[]')$$,
  '22023', 'at least one branch is required');
select tests.throws_ok($$select * from identity.platform_onboard_tenant('zz-bad', 'Bad (synthetic)', 'Asia/Kolkata', 'a@bad.example', '[{"code":"main","name":"Main"},{"code":"Bad Code","name":"X"}]')$$,
  '22023', 'a bad second branch rejects the whole request');
select tests.ok(not exists (select 1 from identity.tenants where code in ('zz-dup', 'zz-none', 'zz-bad')), 'rejected requests leave no tenant behind (atomic)');

create temp table t77 on commit drop as
  select * from identity.platform_onboard_tenant('zz-onboard77', 'Zz-QA Onboard Hospital', 'Asia/Kolkata', 'zz-qa-admin@onboard77.example',
    '[{"code":"hyd-main","name":"Hyderabad Main","address":"Synthetic Rd 1"},{"code":"blr","name":"Bengaluru"},{"code":"chn","name":"Chennai"}]');
grant select on t77 to authenticated;
select tests.ok((select branch_count = 3 and settings_seeded = 5 and token is not null from t77), 'returns the invite, 3 branches and 5 seeded settings');

select tests.as_superuser();
select tests.ok((select count(*) = 3 from identity.branches b where b.tenant_id = (select tenant_id from t77)), 'all three branches exist');
select tests.ok((select address = 'Synthetic Rd 1' from identity.branches b where b.tenant_id = (select tenant_id from t77) and code = 'hyd-main'), 'main branch keeps its address');
select tests.ok((select rx_validity_days = 45 and near_expiry_days = 90 from pharmacy.tenant_setting where tenant_id = (select tenant_id from t77)),
  'pharmacy settings come from the config table (edited value 45 used)');
select tests.ok((select maker_checker_threshold_paise = 20000 from billing.approval_settings where tenant_id = (select tenant_id from t77))
  and exists (select 1 from appointment.reminder_settings where tenant_id = (select tenant_id from t77) and quiet_start = '21:00')
  and exists (select 1 from appointment.tenant_settings where tenant_id = (select tenant_id from t77))
  and exists (select 1 from patient.registration_settings where tenant_id = (select tenant_id from t77) and guardian_required_below_age_years = 18),
  'billing, appointment, reminder and registration defaults are seeded');
select tests.ok((select count(*) = 1 from identity.invite_links l where l.tenant_id = (select tenant_id from t77)), 'one first-admin invite');
select tests.authenticate_as('op-77@medicore.example');
select tests.throws_ok($$select * from identity.platform_create_tenant('zz-onboard77', 'Again', 'Asia/Kolkata', 'a@b.example')$$,
  '23505', 'hospital codes stay unique');

-- isolation: an existing tenant's admin sees nothing of the new tenant
select tests.authenticate_as('admin@alpha.example');
select tests.ok((select count(*) = 0 from identity.branches b where b.tenant_id = (select tenant_id from t77)), 'Alpha admin cannot see the new tenant''s branches');
select tests.ok((select count(*) = 0 from identity.tenants t where t.id = (select tenant_id from t77)), 'Alpha admin cannot see the new tenant');
select tests.ok(identity.my_tenant_grant_v1((select tenant_id from t77)) is null, 'Alpha admin gets no grant for the new tenant');

rollback;
