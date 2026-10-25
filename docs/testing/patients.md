# Patients test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## PAT-001

[Notion case](https://app.notion.com/p/404ead9eb8a881a392e8f2aa4402fa64)

**Register new patient** · P0 · happy · Role: receptionist

- Preconditions: —
- Steps: Patients > New; fill name, DOB, phone, consent
- Test data: Synthetic "QA Ravi", +919000000001
- Expected: MRN assigned by server; patient shows age
- Rule / code: `App.tsx patients/new; patients migrations`

## PAT-002

[Notion case](https://app.notion.com/p/404ead9eb8a881238d5ecccf3c128c8d)

**Duplicate phone warning** · P1 · data-integrity · Role: receptionist

- Preconditions: Patient with phone X exists
- Steps: Register another with phone X
- Test data: Same phone
- Expected: "duplicate_phone: another patient in this hospital already has this phone number"
- Rule / code: `20261022130000_patients_tenant_wide_chart.sql`

## PAT-003

[Notion case](https://app.notion.com/p/404ead9eb8a8819b85c8e5616b4261ee)

**ABHA number unique per tenant** · P0 · data-integrity · Role: receptionist

- Preconditions: Patient with ABHA N
- Steps: Register another with ABHA N
- Test data: Synthetic ABHA
- Expected: 409 conflict; unique index patients_tenant_abha_key
- Rule / code: `20261022130300_patients_live_identifier_keys.sql`

## PAT-004

[Notion case](https://app.notion.com/p/404ead9eb8a881b388dbf6795389d738)

**Same ABHA allowed in another tenant** · P2 · edge · Role: receptionist

- Preconditions: Tenant B has ABHA N
- Steps: Register ABHA N in tenant A
- Test data: —
- Expected: Allowed (index is per tenant)
- Rule / code: `patients_live_identifier_keys.sql`

## PAT-005

[Notion case](https://app.notion.com/p/404ead9eb8a881b497d6c80d82316182)

**Same ABHA reusable after delete/merge** · P2 · edge · Role: receptionist

- Preconditions: Old chart soft-deleted
- Steps: Register ABHA N again
- Test data: —
- Expected: Allowed (index excludes deleted and merged)
- Rule / code: `patients_live_identifier_keys.sql`

## PAT-006

[Notion case](https://app.notion.com/p/404ead9eb8a881d88600f926b70e9fae)

**Age from DOB, birthday boundary** · P1 · edge · Role: receptionist

- Preconditions: —
- Steps: View patient born today minus 30y +1 day, and exactly 30y
- Test data: DOB 1996-10-26 / 1996-10-25 on 2026-10-25
- Expected: "29 y" and "30 y"
- Rule / code: `patientLabel.ts ageOn`

## PAT-007

[Notion case](https://app.notion.com/p/404ead9eb8a8810e8788ce1460fdeb8c)

**Age for 29 Feb DOB** · P3 · edge · Role: receptionist

- Preconditions: —
- Steps: Patient DOB 2000-02-29 viewed on 2026-02-28 and 2026-03-01
- Test data: —
- Expected: 25 y then 26 y
- Rule / code: `patientLabel.ts ageOn`

## PAT-008

[Notion case](https://app.notion.com/p/404ead9eb8a88127bb25c531ded9a34a)

**Future DOB shows no age** · P3 · edge · Role: receptionist

- Preconditions: —
- Steps: Enter DOB tomorrow
- Test data: —
- Expected: Age blank (ageOn returns null); check whether save is rejected
- Rule / code: `patientLabel.ts ageOn`

## PAT-009

[Notion case](https://app.notion.com/p/404ead9eb8a881ebac7ad0b58b377a4c)

**Phone must be E.164** · P2 · negative · Role: receptionist

- Preconditions: —
- Steps: Phone "98765"
- Test data: 98765
- Expected: "phone must be E.164"
- Rule / code: `patients migrations`

## PAT-010

[Notion case](https://app.notion.com/p/404ead9eb8a8819abe7cc7724e7f4111)

**MRN is immutable** · P1 · security · Role: tenant_admin

- Preconditions: Existing patient
- Steps: Edit MRN via API
- Test data: —
- Expected: "mrn is immutable"
- Rule / code: `patients migrations`

## PAT-011

[Notion case](https://app.notion.com/p/404ead9eb8a881da9f41f3fd18a92d26)

**Edit patient permission** · P1 · security · Role: doctor

- Preconditions: Doctor login
- Steps: Try to edit demographics
- Test data: —
- Expected: No edit control; API "not permitted to edit this patient"
- Rule / code: `permissions.ts patients.edit`

## PAT-012

[Notion case](https://app.notion.com/p/404ead9eb8a881b5aab0fa13a1efe933)

**Delete patient with open appointments blocked** · P1 · data-integrity · Role: receptionist

- Preconditions: Patient has booked appt
- Steps: Delete
- Test data: —
- Expected: "patient has open appointments or queue entries; cancel them first"
- Rule / code: `20261010090000_patient_soft_delete_and_duplicates.sql`

## PAT-013

[Notion case](https://app.notion.com/p/404ead9eb8a881fe9230de21ba480d97)

**Soft delete and restore admin-only** · P1 · happy · Role: tenant_admin

- Preconditions: Deleted patient
- Steps: Restore as reception, then as admin
- Test data: —
- Expected: Reception: "only tenant admins can restore patients"; admin restores
- Rule / code: `patient_soft_delete migration; permissions.ts patients.restore`

## PAT-014

[Notion case](https://app.notion.com/p/404ead9eb8a881029258ca04506636df)

**is_deleted only via functions** · P3 · security · Role: tenant_admin

- Preconditions: —
- Steps: Direct update is_deleted via API body
- Test data: —
- Expected: "is_deleted can only be changed through the soft-delete / restore functions"
- Rule / code: `soft-delete triggers`

## PAT-015

[Notion case](https://app.notion.com/p/404ead9eb8a8811b8ceeef57edb41b70)

**Admin merges duplicate charts** · P0 · data-integrity · Role: tenant_admin

- Preconditions: Two charts same person with bills
- Steps: Merge B into A
- Test data: —
- Expected: B shows merged; A has B's appointments and bills
- Rule / code: `20261022130200_patients_merge.sql; 20261025240100_billing_patient_merge_moves_bills.sql`

## PAT-016

[Notion case](https://app.notion.com/p/404ead9eb8a8816c86dac0508b153700)

**Merge into itself blocked** · P2 · negative · Role: tenant_admin

- Preconditions: —
- Steps: Merge A into A
- Test data: —
- Expected: "a chart cannot be merged into itself"
- Rule / code: `patients_merge.sql`

## PAT-017

[Notion case](https://app.notion.com/p/404ead9eb8a8818997bff4492ef1fdd2)

**Merged chart cannot be restored/re-merged** · P2 · negative · Role: tenant_admin

- Preconditions: B merged
- Steps: Restore B; merge B again
- Test data: —
- Expected: "merged patient cannot be restored"; "patient is already merged into another chart"
- Rule / code: `patients_merge.sql`

## PAT-018

[Notion case](https://app.notion.com/p/404ead9eb8a88163b5dedfe696bca993)

**Non-admin merge blocked** · P1 · security · Role: receptionist

- Preconditions: —
- Steps: Try merge
- Test data: —
- Expected: "only tenant admins can merge patients"
- Rule / code: `patients_merge.sql`

## PAT-019

[Notion case](https://app.notion.com/p/404ead9eb8a88193ad05e315cd26cfb2)

**Search needs 2 chars** · P3 · edge · Role: receptionist

- Preconditions: —
- Steps: Type 1 char in patient picker
- Test data: "R"
- Expected: No search until 2 chars
- Rule / code: `patientLabel.ts PATIENT_PICKER_MIN_CHARS`

## PAT-020

[Notion case](https://app.notion.com/p/404ead9eb8a881658a77d62c87a4e635)

**Pharmacist cannot search patients** · P1 · security · Role: pharmacist

- Preconditions: —
- Steps: Open /patients
- Test data: —
- Expected: Blocked; API "not permitted to search patients"
- Rule / code: `permissions.ts (pharmacist has no patients.view)`
