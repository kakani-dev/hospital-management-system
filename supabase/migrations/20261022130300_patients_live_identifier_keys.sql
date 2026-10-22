-- Live email, phone and ABHA are unique per hospital among charts that are still in use.
-- is_deleted is generated from deleted_at, so NOT is_deleted is the live-chart predicate
-- (the same spelling as the other patient indexes). merged_into_patient_id IS NULL excludes a merged chart
-- even if a later change ever separated the two. patient.merge_duplicate_charts() has already folded
-- existing duplicates, which is what lets these indexes build.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- Blank emails are not values.
create unique index patients_tenant_email_key
  on patient.patients (tenant_id, lower(btrim(email)))
  where not is_deleted and merged_into_patient_id is null
    and email is not null and btrim(email) <> '';

-- patient_phones has no merged_into column. Merge soft-deletes a duplicate number or moves it
-- onto the survivor before this index is built, so NOT is_deleted is the live set.
create unique index patient_phones_tenant_number_key
  on patient.patient_phones (tenant_id, phone_e164)
  where not is_deleted;
comment on index patient.patient_phones_tenant_number_key is
  'One live E.164 per hospital. Merged charts do not keep a live phone row. Last-10 matches that are not byte-identical are rejected by patient.reject_shared_phone.';

drop index patient.patients_tenant_abha_key;
create unique index patients_tenant_abha_key
  on patient.patients (tenant_id, abha_number)
  where not is_deleted and merged_into_patient_id is null and abha_number is not null;
