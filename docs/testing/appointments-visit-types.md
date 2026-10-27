# Appointments & visit types test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## APT-001

[Notion case](https://app.notion.com/p/404ead9eb8a88193942cf83b3bce69c8)

**Book new consult** · P0 · happy · Role: receptionist

- Preconditions: Doctor working today
- Steps: Appointments > book New consult
- Test data: —
- Expected: Booked; default fee ₹500, 30 min
- Rule / code: `20261025280000_scheduling_visit_types_and_nmc.sql defaults`

## APT-002

[Notion case](https://app.notion.com/p/404ead9eb8a881e49f17f8ec0e969763)

**Free follow-up within 7 days of new consult** · P0 · happy · Role: receptionist

- Preconditions: New consult done day D
- Steps: Book Follow-up on D+7
- Test data: —
- Expected: Follow-up fee ₹0
- Rule / code: `visit_types new_consult window 7, fee 0`

## APT-003

[Notion case](https://app.notion.com/p/404ead9eb8a8812aa4d6ef2f3446855d)

**Follow-up after window charged** · P0 · edge · Role: receptionist

- Preconditions: New consult day D
- Steps: Book follow-up D+8
- Test data: —
- Expected: Normal Follow-up fee ₹200
- Rule / code: `visit_types_and_nmc.sql follow_up 20000`

## APT-004

[Notion case](https://app.notion.com/p/404ead9eb8a881738872c2c57ec5b4d9)

**Review opens 14-day ₹100 follow-up** · P1 · edge · Role: receptionist

- Preconditions: Review on D
- Steps: Follow-up D+14 and D+15
- Test data: —
- Expected: ₹100 then ₹200
- Rule / code: `visit_types review 14/10000`

## APT-005

[Notion case](https://app.notion.com/p/404ead9eb8a88188820dfdc42df0d836)

**Teleconsult 3-day free follow-up** · P2 · edge · Role: receptionist

- Preconditions: Teleconsult D
- Steps: Follow-up D+3, D+4
- Test data: —
- Expected: ₹0 then ₹200
- Rule / code: `visit_types teleconsult 3/0`

## APT-006

[Notion case](https://app.notion.com/p/404ead9eb8a8818e8f74ea94771895b1)

**Emergency gives no follow-up entitlement** · P2 · edge · Role: receptionist

- Preconditions: Emergency visit D
- Steps: Follow-up D+1
- Test data: —
- Expected: ₹200 (null window)
- Rule / code: `visit_types emergency null`

## APT-007

[Notion case](https://app.notion.com/p/404ead9eb8a881e9b7cbe8f39a2ab2e7)

**Follow-up must stay same patient** · P1 · negative · Role: receptionist

- Preconditions: Parent appt patient A
- Steps: Book follow-up for patient B
- Test data: —
- Expected: "follow_up_patient_mismatch: a follow-up must stay with the same patient"
- Rule / code: `any_clinician_followup.sql`

## APT-008

[Notion case](https://app.notion.com/p/404ead9eb8a8817c904cc9dacc9f65e0)

**Branch override of visit type** · P2 · edge · Role: tenant_admin

- Preconditions: Branch override fee/window
- Steps: Book at override branch vs other
- Test data: —
- Expected: Override applies only at that branch; null inherits
- Rule / code: `visit_type_overrides comment`

## APT-009

[Notion case](https://app.notion.com/p/404ead9eb8a881629891faa4cd571939)

**Window value bounds 0..366** · P3 · edge · Role: tenant_admin

- Preconditions: Admin > Visit types
- Steps: Set 367 days
- Test data: —
- Expected: Rejected (check visit_types_window)
- Rule / code: `visit_types_and_nmc.sql:51`

## APT-010

[Notion case](https://app.notion.com/p/404ead9eb8a8810d9defefe2debf2f57)

**Fee override on booking** · P1 · happy · Role: receptionist

- Preconditions: —
- Steps: Book and override fee
- Test data: —
- Expected: Draft consult bill uses overridden fee
- Rule / code: `20261025280100_billing_visit_fee_on_consult_draft.sql`

## APT-011

[Notion case](https://app.notion.com/p/404ead9eb8a881f09865dd2c80814615)

**Booking in the past blocked** · P1 · negative · Role: receptionist

- Preconditions: —
- Steps: Book yesterday
- Test data: —
- Expected: "appointment_in_past: appointments cannot be booked for an earlier day"
- Rule / code: `20261020120000_appointment_bookable_window.sql`

## APT-012

[Notion case](https://app.notion.com/p/404ead9eb8a88194a9abfde085857868)

**Outside working hours needs admin + reason** · P1 · negative · Role: receptionist

- Preconditions: Doctor off at 22:00
- Steps: Book 22:00 as reception; then admin without reason
- Test data: —
- Expected: "outside_working_hours..."; reception "only admins can book outside working hours"; admin w/o reason "A reason is required..."
- Rule / code: `business_rules.sql; 20261025220000_scheduling_hours_override_reason.sql`

## APT-013

[Notion case](https://app.notion.com/p/404ead9eb8a88129ad9ee73ad832cb42)

**Doctor not at branch** · P1 · negative · Role: receptionist

- Preconditions: Doctor only at branch 1
- Steps: Book at branch 2
- Test data: —
- Expected: "practitioner_not_at_branch: the doctor does not work at this branch"
- Rule / code: `20261022150000_scheduling_practitioner_branches.sql`

## APT-014

[Notion case](https://app.notion.com/p/404ead9eb8a881078570c4fd426fba6d)

**Inactive practitioner** · P2 · negative · Role: receptionist

- Preconditions: Deactivated doctor
- Steps: Book
- Test data: —
- Expected: "practitioner_inactive"
- Rule / code: `scheduling migrations`

## APT-015

[Notion case](https://app.notion.com/p/404ead9eb8a881f2a6f9c17704f2fbca)

**Reschedule only booked appt** · P2 · negative · Role: receptionist

- Preconditions: Checked-in appt
- Steps: Reschedule
- Test data: —
- Expected: "invalid_transition:reschedule_not_booked"
- Rule / code: `appointment state machine`

## APT-016

[Notion case](https://app.notion.com/p/404ead9eb8a8814caafbf466c6744edf)

**Date range max 31 days** · P3 · boundary · Role: receptionist

- Preconditions: —
- Steps: Query appointments for 32-day range
- Test data: —
- Expected: "invalid date range (max 31 days)"
- Rule / code: `20261010090100_appointment_schema.sql`

## APT-017

[Notion case](https://app.notion.com/p/404ead9eb8a881bb9cdbc9a2ec39bb43)

**Two receptionists book same slot** · P1 · concurrency · Role: receptionist

- Preconditions: Two sessions
- Steps: Book same doctor+slot simultaneously
- Test data: —
- Expected: One succeeds; other gets 409
- Rule / code: `appointment_schema.sql exclusion/unique (23P01 -> conflict)`

## APT-018

[Notion case](https://app.notion.com/p/404ead9eb8a881db9986c5261431b048)

**Nurse can book but not cancel** · P2 · security · Role: nurse

- Preconditions: —
- Steps: Book; then cancel
- Test data: —
- Expected: Book ok; cancel hidden/denied
- Rule / code: `permissions.ts nurse`

## APT-019

[Notion case](https://app.notion.com/p/404ead9eb8a88192975ff3eb06666bf7)

**hours_override cannot be cleared** · P3 · data-integrity · Role: tenant_admin

- Preconditions: Override-booked appt
- Steps: Clear override via API
- Test data: —
- Expected: "hours_override cannot be cleared"
- Rule / code: `hours_override_reason.sql`

## APT-020

[Notion case](https://app.notion.com/p/404ead9eb8a881488886fcb7238fb82f)

**Default visit types exist** · P1 · data-integrity · Role: tenant_admin

- Preconditions: Any tenant
- Steps: Admin > Visit types
- Test data: —
- Expected: 5 defaults: new consult, follow-up, review, emergency, teleconsult
- Rule / code: `ensure_default_visit_types`

## APT-021

**Second follow-up in the window is charged** · P1 · functional · Role: receptionist

- Preconditions: New consult D (7 days, free, 1 free follow-up); one follow-up at D+2 used it
- Steps: Book another Follow-up with the same doctor at D+4
- Test data: Synthetic patient
- Expected: ₹200 normal fee; no bill note; the suggestion says the free follow-up is already used
- Rule / code: `VisitTypeRules.QuoteFor, LatestPriorAsync`

## APT-022

**Cancelled free follow-up gives the slot back** · P2 · functional · Role: receptionist

- Preconditions: APT-021 preconditions
- Steps: Cancel the D+2 follow-up, then book a Follow-up at D+5
- Test data: Synthetic patient
- Expected: ₹0; cancelled and no-show follow-ups do not count
- Rule / code: `LatestPriorAsync used count`

## APT-023

**Free follow-up note on the bill; other services charged** · P1 · functional · Role: billing

- Preconditions: A ₹0 follow-up checked in
- Steps: Open the draft bill and add a lab test
- Test data: Synthetic lab ₹300
- Expected: CONSULT ₹0 with "Free follow-up (within 7 days of <date>)"; lab line ₹300 with no note
- Rule / code: `billing.ensure_draft, appointment_consultation_fee_v2, 54_free_followup_bill_note_test.sql`

## APT-024

**Admin edits follow-up fee and free count** · P2 · functional · Role: tenant_admin

- Preconditions: Any visit type
- Steps: Admin > Visit types: set Follow-up fee and Free follow-ups (0-50, blank = no limit)
- Test data: —
- Expected: Saved; 51 is rejected; next booking uses the new values, old bookings keep their snapshot
- Rule / code: `VisitTypesPage, ValidFreeLimit`
