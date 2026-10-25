-- Branch payment accounts (#63). Every case is one assertion. The transaction rolls back.
begin;

select tests.ok(
  (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'billing' and c.relname = 'payment_account'),
  'RLS is enabled on billing.payment_account');

select tests.ok(
  not exists (select 1 from information_schema.columns
              where table_schema = 'billing' and table_name = 'payment_account'
                and column_name ~ 'account_number|full_number'),
  'no column can hold a full account number');

select tests.ok(
  (select count(*) = 5 from information_schema.columns
   where table_schema = 'billing' and table_name = 'payment_account'
     and column_name in ('created_on', 'created_by', 'updated_on', 'updated_by', 'is_deleted')),
  'payment_account carries the audit fields');

select tests.ok(
  (select not has_function_privilege('anon', oid, 'execute') and not has_function_privilege('authenticated', oid, 'execute')
   from pg_proc where oid = 'billing.add_payment_account(uuid,uuid,jsonb)'::regprocedure),
  'anon and authenticated cannot call add_payment_account');

do $$
declare
  v_tenant uuid := '11111111-1111-4111-8111-111111111111';
  v_branch uuid := 'a1111111-0000-4000-8000-000000000001';
  v_east uuid := 'a1111111-0000-4000-8000-000000000002';
  v_beta uuid := '22222222-2222-4222-8222-222222222222';
  v_beta_branch uuid := 'b2222222-0000-4000-8000-000000000001';
  v_patient uuid := 'aa000000-0000-4000-8000-000000000001';
  v_upi1 jsonb;
  v_upi2 jsonb;
  v_again jsonb;
  v_bank jsonb;
  v_doc jsonb;
  v_acct uuid;
  v_pay uuid;
  v_refund uuid;
  v_ok boolean;
  v_state text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000001', true);
  execute 'set local role hms_svc_billing';
  perform billing.ensure_defaults(v_tenant);

  -- A branch with no account configured.
  perform tests.ok(billing.payment_accounts(v_tenant, v_branch) = '[]'::jsonb
    and billing.branch_upi_payee(v_tenant, v_branch) is null,
    'a branch with no accounts lists none and has no UPI payee (no stub fallback)');
  v_doc := billing.open_account(v_tenant, jsonb_build_object('patientId', v_patient, 'branchId', v_branch));
  v_acct := (v_doc ->> 'accountId')::uuid;
  v_doc := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'advance', 'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 1000))));
  perform tests.ok((v_doc -> 'tenders' -> 0 -> 'paymentAccountId') = 'null'::jsonb,
    'a UPI payment at a branch with no account still records, unassigned');

  -- Invalid input.
  foreach v_state in array array['not-a-vpa', 'a@', '@bank', 'two words@okhdfc'] loop
    v_ok := false;
    begin
      perform billing.add_payment_account(v_tenant, v_branch, jsonb_build_object('mode', 'upi', 'label', 'x', 'vpa', v_state));
    exception when sqlstate '22023' then v_ok := true;
    end;
    perform tests.ok(v_ok, format('invalid VPA %L is rejected', v_state));
  end loop;
  foreach v_state in array array['HDFC1234567', 'HDF00123456', 'HDFC01234567'] loop
    v_ok := false;
    begin
      perform billing.add_payment_account(v_tenant, v_branch, jsonb_build_object(
        'mode', 'bank', 'label', 'x', 'bankName', 'HDFC', 'accountNumber', '000111222333', 'ifsc', v_state));
    exception when sqlstate '22023' then v_ok := true;
    end;
    perform tests.ok(v_ok, format('invalid IFSC %L is rejected', v_state));
  end loop;
  v_ok := false;
  begin
    perform billing.add_payment_account(v_tenant, v_branch, jsonb_build_object('mode', 'cash', 'label', 'x'));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform tests.ok(v_ok, 'cash is not a payment account mode');

  -- Masking: only the last 4 digits are kept.
  v_bank := billing.add_payment_account(v_tenant, v_branch, jsonb_build_object(
    'mode', 'bank', 'label', 'Current a/c', 'bankName', 'Synthetic Bank', 'accountNumber', '1234 5678 9012', 'ifsc', 'sbin0001234'));
  perform tests.ok(v_bank ->> 'maskedAccount' = 'XXXX9012' and v_bank ->> 'ifsc' = 'SBIN0001234'
    and (select account_last4 from billing.payment_account where id = (v_bank ->> 'id')::uuid) = '9012'
    and position('123456789012' in v_bank::text) = 0,
    'a bank account stores and returns only the last 4 digits');
  perform tests.ok((v_bank ->> 'isDefault')::boolean, 'the first account of a mode becomes the default');

  -- Double-submit.
  v_upi1 := billing.add_payment_account(v_tenant, v_branch, jsonb_build_object('mode', 'upi', 'label', 'Front desk', 'vpa', 'alpha.main@okaxis'));
  v_again := billing.add_payment_account(v_tenant, v_branch, jsonb_build_object('mode', 'upi', 'label', 'Front desk', 'vpa', 'Alpha.Main@okaxis'));
  perform tests.ok(v_again ->> 'id' = v_upi1 ->> 'id'
    and (select count(*) from billing.payment_account where tenant_id = v_tenant and branch_id = v_branch and mode = 'upi' and not is_deleted) = 1,
    'submitting the same VPA twice returns one account');

  -- Default per mode and the QR payee.
  v_upi2 := billing.add_payment_account(v_tenant, v_branch, jsonb_build_object('mode', 'upi', 'label', 'Pharmacy', 'vpa', 'alpha.pharm@okicici', 'isDefault', true));
  perform tests.ok((select count(*) from billing.payment_account where tenant_id = v_tenant and branch_id = v_branch and mode = 'upi' and is_default) = 1
    and billing.branch_upi_payee(v_tenant, v_branch) ->> 'vpa' = 'alpha.pharm@okicici',
    'a new default replaces the old one, and the QR uses the branch default VPA');

  -- Payment records the receiving account.
  v_doc := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'advance', 'tenders', jsonb_build_array(jsonb_build_object('mode', 'upi', 'amountPaise', 5000))));
  v_pay := (v_doc ->> 'id')::uuid;
  perform tests.ok(v_doc -> 'tenders' -> 0 ->> 'paymentAccountId' = v_upi2 ->> 'id'
    and v_doc -> 'tenders' -> 0 ->> 'payeeVpa' = 'alpha.pharm@okicici',
    'a UPI payment records the branch default account on the receipt');
  v_doc := billing.record_payment(v_tenant, gen_random_uuid(), jsonb_build_object(
    'accountId', v_acct, 'kind', 'advance', 'tenders', jsonb_build_array(jsonb_build_object('mode', 'card', 'amountPaise', 700))));
  perform tests.ok((v_doc -> 'tenders' -> 0 -> 'paymentAccountId') = 'null'::jsonb, 'a card payment at a branch with no terminal records unassigned');
  execute 'reset role';
  v_ok := false;
  begin
    insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise, payment_account_id)
    values (v_tenant, v_pay, 'cash', 1, (v_bank ->> 'id')::uuid);
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform tests.ok(v_ok, 'a cash tender cannot carry a payment account');
  execute 'set local role hms_svc_billing';

  -- Concurrent default changes: the partial unique index is the backstop for the advisory lock.
  execute 'reset role';
  v_ok := false;
  begin
    update billing.payment_account set is_default = true where id = (v_upi1 ->> 'id')::uuid;
  exception when unique_violation then v_ok := true;
  end;
  perform tests.ok(v_ok, 'two defaults for one branch and mode cannot both commit');
  execute 'set local role hms_svc_billing';
  perform billing.update_payment_account(v_tenant, (v_upi1 ->> 'id')::uuid, '{"isDefault": true}');
  perform billing.update_payment_account(v_tenant, (v_upi2 ->> 'id')::uuid, '{"isDefault": true}');
  perform tests.ok((select array_agg(id) from billing.payment_account where branch_id = v_branch and mode = 'upi' and is_default)
    = array[(v_upi2 ->> 'id')::uuid], 'back-to-back default changes leave exactly the last one default');

  -- Deactivated account on an old payment.
  v_doc := billing.update_payment_account(v_tenant, (v_upi2 ->> 'id')::uuid, '{"isActive": false}');
  perform tests.ok(not (v_doc ->> 'isDefault')::boolean
    and (select is_default from billing.payment_account where id = (v_upi1 ->> 'id')::uuid),
    'deactivating the default promotes the next active account');
  perform tests.ok(billing.receipt_json(v_pay) -> 'tenders' -> 0 ->> 'paymentAccountId' = v_upi2 ->> 'id',
    'an old payment keeps its now-inactive account');
  perform tests.ok(exists (select 1 from jsonb_array_elements(billing.day_end_accounts(v_tenant, v_branch, billing.branch_day(v_branch)) -> 'accounts') a
    where a ->> 'paymentAccountId' = v_upi2 ->> 'id' and not (a ->> 'isActive')::boolean and (a ->> 'netPaise')::bigint = 5000),
    'day-end still shows the inactive account with its takings');
  v_ok := false;
  begin
    perform billing.update_payment_account(v_tenant, (v_upi2 ->> 'id')::uuid, '{"isDefault": true}');
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform tests.ok(v_ok, 'an inactive account cannot be made default');
  v_refund := (billing.request_refund(v_tenant, v_pay, '{"amountPaise": 2000, "mode": "upi"}') ->> 'id')::uuid;
  perform tests.ok((select payment_account_id from billing.payment_tender where payment_id = v_refund) = (v_upi2 ->> 'id')::uuid,
    'a refund leaves from the account that received the money, even if inactive');
  v_ok := false;
  begin
    execute 'reset role';
    insert into billing.payment_tender (tenant_id, payment_id, mode, amount_paise, payment_account_id)
    values (v_tenant, v_pay, 'upi', 1, (v_upi2 ->> 'id')::uuid);
  exception when sqlstate '22023' then v_ok := true;
  end;
  execute 'set local role hms_svc_billing';
  perform tests.ok(v_ok, 'a new tender cannot be booked to an inactive account');

  -- Deleting a default.
  perform billing.delete_payment_account(v_tenant, (v_upi1 ->> 'id')::uuid);
  perform tests.ok(billing.branch_upi_payee(v_tenant, v_branch) is null
    and not exists (select 1 from billing.payment_account where branch_id = v_branch and mode = 'upi' and is_default),
    'deleting the only active default leaves the mode with no default and no QR payee');
  v_ok := false;
  begin
    perform billing.delete_payment_account(v_tenant, (v_upi1 ->> 'id')::uuid);
  exception when sqlstate 'P0002' then v_ok := true;
  end;
  perform tests.ok(v_ok, 'deleting an already deleted account is not found');
  v_again := billing.add_payment_account(v_tenant, v_branch, jsonb_build_object('mode', 'upi', 'label', 'Front desk', 'vpa', 'alpha.main@okaxis'));
  perform tests.ok(v_again ->> 'id' <> v_upi1 ->> 'id' and (v_again ->> 'isDefault')::boolean,
    'a deleted VPA can be added again and becomes the default');

  -- CA register groups by account.
  v_doc := billing.account_register(v_tenant, billing.branch_day(v_branch), billing.branch_day(v_branch), null);
  perform tests.ok(exists (select 1 from jsonb_array_elements(v_doc -> 'accounts') a
      where a ->> 'paymentAccountId' = v_upi2 ->> 'id' and (a ->> 'receivedPaise')::bigint = 5000 and (a ->> 'refundedPaise')::bigint = 2000)
    and exists (select 1 from jsonb_array_elements(v_doc -> 'accounts') a where a ->> 'mode' = 'upi' and a ->> 'label' = 'Unassigned' and (a ->> 'netPaise')::bigint = 1000),
    'the CA register nets refunds per account and keeps unassigned UPI separate');

  -- Card terminal.
  v_doc := billing.add_payment_account(v_tenant, v_east, jsonb_build_object('mode', 'card', 'label', 'POS 1', 'mid', 'mid12345', 'tid', 't0001'));
  perform tests.ok(v_doc ->> 'mid' = 'MID12345' and v_doc ->> 'tid' = 'T0001', 'a card terminal stores MID and TID');

  -- Cross-tenant: Alpha cannot read, edit or delete Beta rows, nor add to a Beta branch.
  execute 'reset role';
  insert into billing.payment_account (tenant_id, branch_id, mode, label, vpa, created_by, updated_by)
  values (v_beta, v_beta_branch, 'upi', 'Beta', 'beta.central@okaxis', '0b000000-0000-4000-8000-000000000001', '0b000000-0000-4000-8000-000000000001');
  execute 'set local role hms_svc_billing';
  perform tests.ok(not exists (select 1 from billing.payment_account where tenant_id = v_beta), 'RLS hides another tenant''s accounts');
  v_ok := false;
  begin
    perform billing.update_payment_account(v_tenant, (select id from billing.payment_account where vpa = 'beta.central@okaxis'), '{"label": "pwned"}');
  exception when sqlstate 'P0002' then v_ok := true;
  end;
  perform tests.ok(v_ok, 'another tenant''s account id is not found');
  v_ok := false;
  begin
    perform billing.add_payment_account(v_beta, v_beta_branch, jsonb_build_object('mode', 'upi', 'label', 'x', 'vpa', 'evil@okaxis'));
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform tests.ok(v_ok, 'a caller cannot add an account to a tenant they do not belong to');
  v_ok := false;
  begin
    perform billing.account_register(v_beta, current_date, current_date, null);
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform tests.ok(v_ok, 'a caller cannot read another tenant''s account register');

  -- Role boundary: reception can read but not configure.
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', '0a000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '0a000000-0000-4000-8000-000000000002', true);
  v_ok := false;
  begin
    perform billing.add_payment_account(v_tenant, v_branch, jsonb_build_object('mode', 'upi', 'label', 'x', 'vpa', 'rec@okaxis'));
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform tests.ok(v_ok, 'a receptionist cannot add a payment account');
  perform tests.ok(jsonb_array_length(billing.payment_accounts(v_tenant, v_branch)) >= 1, 'a receptionist can list the branch accounts');
  execute 'reset role';
end
$$;

rollback;
