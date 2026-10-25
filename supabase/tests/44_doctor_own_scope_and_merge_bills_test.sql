-- A doctor sees only their own charts, visits and tokens. Merge moves billing onto the survivor.
begin;

select tests.authenticate_as('doctor@beta.example');
select tests.ok(
  (select count(*) = 1 from patient.patients)
  and exists (select 1 from patient.patients where id = 'bb000000-0000-4000-8000-000000000001'),
  'beta doctor sees only the patient on their own visit');
select tests.ok(
  exists (select 1 from appointment.appointments where id = 'e2222222-0000-4000-8000-000000000001'),
  'beta doctor sees their own appointment');

select tests.as_superuser();
insert into appointment.practitioners (id, tenant_id, display_name)
values ('c2440000-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'Dr Other Beta (synthetic)');
insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id)
values ('22222222-2222-4222-8222-222222222222', 'c2440000-0000-4000-8000-000000000001', 'b2222222-0000-4000-8000-000000000001');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('bb244000-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222',
        'b2222222-0000-4000-8000-000000000001', 'Other', 'Chart');
insert into appointment.appointments (id, tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at)
values ('e2440000-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222',
        'b2222222-0000-4000-8000-000000000001', 'c2440000-0000-4000-8000-000000000001',
        'bb244000-0000-4000-8000-000000000001', '2031-04-04 09:00+05:30', '2031-04-04 09:15+05:30');
insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, practitioner_id, status)
values ('f2440000-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222',
        'b2222222-0000-4000-8000-000000000001', '2031-04-04', 2441,
        'bb244000-0000-4000-8000-000000000001', 'c2440000-0000-4000-8000-000000000001', 'waiting');

select tests.authenticate_as('doctor@beta.example');
select tests.ok(
  not exists (select 1 from patient.patients where id = 'bb244000-0000-4000-8000-000000000001')
  and not exists (select 1 from appointment.appointments where id = 'e2440000-0000-4000-8000-000000000001')
  and not exists (select 1 from appointment.queue_entries where id = 'f2440000-0000-4000-8000-000000000001'),
  'a doctor does not see another practitioner''s patient, visit or token');
select tests.throws_ok(
  $$select appointment.set_queue_status('f2440000-0000-4000-8000-000000000001', 'in_consultation')$$,
  '42501', 'a doctor cannot call another practitioner''s token');
select tests.throws_ok(
  $$insert into appointment.appointments (tenant_id, branch_id, practitioner_id, patient_id, starts_at, ends_at, parent_appointment_id)
    values ('22222222-2222-4222-8222-222222222222', 'b2222222-0000-4000-8000-000000000001',
            'c2222222-0000-4000-8000-000000000001', 'bb244000-0000-4000-8000-000000000001',
            '2031-04-11 09:00+05:30', '2031-04-11 09:15+05:30', 'e2440000-0000-4000-8000-000000000001')$$,
  '42501', 'a doctor cannot follow up another clinician''s visit');

-- ---------- merge moves bills ----------
select tests.authenticate_as('admin@alpha.example');
insert into patient.patients (id, tenant_id, registered_branch_id, first_name, last_name)
values ('aa244000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', 'Keep', 'Bill'),
       ('aa244000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111',
        'a1111111-0000-4000-8000-000000000001', 'Copy', 'Bill');
select tests.as_superuser();
insert into billing.billing_account (id, tenant_id, patient_id, branch_id, account_type, source_ref_type, source_ref_id)
values ('a2440000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
        'aa244000-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000001',
        'walk_in', 'none', 'a2440000-0000-4000-8000-0000000000aa');
insert into billing.wallet (id, tenant_id, holder_patient_id)
values ('a2440000-0000-4000-8000-000000000011', '11111111-1111-4111-8111-111111111111', 'aa244000-0000-4000-8000-000000000001'),
       ('a2440000-0000-4000-8000-000000000012', '11111111-1111-4111-8111-111111111111', 'aa244000-0000-4000-8000-000000000002');
insert into billing.wallet_member (id, tenant_id, wallet_id, patient_id)
values ('a2440000-0000-4000-8000-000000000021', '11111111-1111-4111-8111-111111111111',
        'a2440000-0000-4000-8000-000000000011', 'aa244000-0000-4000-8000-000000000001'),
       ('a2440000-0000-4000-8000-000000000022', '11111111-1111-4111-8111-111111111111',
        'a2440000-0000-4000-8000-000000000012', 'aa244000-0000-4000-8000-000000000002');
insert into billing.cost_estimate (id, tenant_id, patient_id, branch_id, valid_until)
values ('a2440000-0000-4000-8000-000000000031', '11111111-1111-4111-8111-111111111111',
        'aa244000-0000-4000-8000-000000000002', 'a1111111-0000-4000-8000-000000000001', '2031-12-31');
insert into billing.bill (id, tenant_id, account_id, bill_kind, status)
values ('a2440000-0000-4000-8000-000000000041', '11111111-1111-4111-8111-111111111111',
        'a2440000-0000-4000-8000-000000000001', 'final', 'draft');
insert into billing.bill (id, tenant_id, account_id, bill_kind, reverses_bill_id, status)
values ('a2440000-0000-4000-8000-000000000042', '11111111-1111-4111-8111-111111111111',
        'a2440000-0000-4000-8000-000000000001', 'credit_note',
        'a2440000-0000-4000-8000-000000000041', 'draft');
insert into billing.approval_request (
  id, tenant_id, action, subject_type, subject_id, amount_paise, requested_by, approver_id, status, decided_at)
values ('a2440000-0000-4000-8000-000000000051', '11111111-1111-4111-8111-111111111111',
        'refund', 'payment', 'a2440000-0000-4000-8000-000000000061', 50000,
        '0a000000-0000-4000-8000-000000000001', '0a000000-0000-4000-8000-000000000001',
        'approved', now());
insert into billing.payment (id, tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise)
values ('a2440000-0000-4000-8000-000000000061', '11111111-1111-4111-8111-111111111111',
        'a2440000-0000-4000-8000-000000000001', 'M244-PAY',
        'a2440000-0000-4000-8000-000000000061', 'payment', 50000);
insert into billing.payment (
  id, tenant_id, account_id, receipt_no, idempotency_key, kind, amount_paise,
  refund_of_payment_id, approval_id, credit_note_id)
values ('a2440000-0000-4000-8000-000000000062', '11111111-1111-4111-8111-111111111111',
        'a2440000-0000-4000-8000-000000000001', 'M244-RFND',
        'a2440000-0000-4000-8000-000000000062', 'refund', 50000,
        'a2440000-0000-4000-8000-000000000061', 'a2440000-0000-4000-8000-000000000051',
        'a2440000-0000-4000-8000-000000000042');

select tests.authenticate_as('reception@alpha.example');
select tests.throws_ok(
  $$select patient.merge_patients('aa244000-0000-4000-8000-000000000001', 'aa244000-0000-4000-8000-000000000002', 'same person')$$,
  '42501', 'front desk cannot merge charts');

select tests.authenticate_as('admin@alpha.example');
select patient.merge_patients(
  'aa244000-0000-4000-8000-000000000001', 'aa244000-0000-4000-8000-000000000002', 'Same person, second chart');

select tests.as_superuser();
select tests.ok(
  (select patient_id = 'aa244000-0000-4000-8000-000000000001' from billing.billing_account where id = 'a2440000-0000-4000-8000-000000000001')
  and (select patient_id = 'aa244000-0000-4000-8000-000000000001' and not is_deleted from billing.cost_estimate where id = 'a2440000-0000-4000-8000-000000000031')
  and (select is_deleted from billing.wallet where id = 'a2440000-0000-4000-8000-000000000012')
  and not (select is_deleted from billing.wallet where id = 'a2440000-0000-4000-8000-000000000011')
  and (select is_deleted and patient_id = 'aa244000-0000-4000-8000-000000000002' from billing.wallet_member where id = 'a2440000-0000-4000-8000-000000000022'),
  'merge moves the account and estimate, and retires the duplicate wallet when the survivor already has one');
select tests.ok(
  exists (select 1 from audit.audit_log
           where table_name = 'patients' and record_id = 'aa244000-0000-4000-8000-000000000002'
             and action = 'UPDATE' and (new_data ->> 'merged_into_patient_id') = 'aa244000-0000-4000-8000-000000000001'),
  'merge writes an audit row for the soft-deleted duplicate');
select tests.ok(
  (select patient_id = 'aa244000-0000-4000-8000-000000000001' from billing.billing_account where id = 'a2440000-0000-4000-8000-000000000001')
  and (select account_id = 'a2440000-0000-4000-8000-000000000001' and not is_deleted from billing.bill where id = 'a2440000-0000-4000-8000-000000000041')
  and (select account_id = 'a2440000-0000-4000-8000-000000000001' and reverses_bill_id = 'a2440000-0000-4000-8000-000000000041' and not is_deleted
       from billing.bill where id = 'a2440000-0000-4000-8000-000000000042')
  and (select account_id = 'a2440000-0000-4000-8000-000000000001' and credit_note_id = 'a2440000-0000-4000-8000-000000000042'
            and refund_of_payment_id = 'a2440000-0000-4000-8000-000000000061' and not is_deleted
       from billing.payment where id = 'a2440000-0000-4000-8000-000000000062'),
  'merge moves the bill, refund and credit note with the account onto the survivor');

rollback;
