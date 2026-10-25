# Doctor scoping test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## DOC-001

[Notion case](https://app.notion.com/p/404ead9eb8a881649a07f7988774f7fe)

**Doctor sees only own queue/appointments** · P0 · security · Role: doctor

- Preconditions: Two doctors at a branch
- Steps: Log in as doctor 1; open My day / Queue
- Test data: —
- Expected: Only doctor 1's patients
- Rule / code: `20261025240000_scheduling_doctor_own_scope.sql`

## DOC-002

[Notion case](https://app.notion.com/p/404ead9eb8a88128b7caf9678b69dfa3)

**Doctor cannot advance another doctor's queue entry** · P1 · security · Role: doctor

- Preconditions: Entry for doctor 2
- Steps: Call queue advance on it
- Test data: —
- Expected: 403 / "not permitted to set queue status"
- Rule / code: `doctor_own_scope.sql; permissions.ts queue.consult_own`

## DOC-003

[Notion case](https://app.notion.com/p/404ead9eb8a881e2ae98f0619c1c944b)

**Doctor books own follow-up** · P1 · happy · Role: doctor

- Preconditions: Doctor's completed visit
- Steps: Book follow-up from visit
- Test data: —
- Expected: Booked; same patient enforced
- Rule / code: `permissions.ts appointments.book_followup_own; 20261022130100_scheduling_any_clinician_followup.sql`

## DOC-004

[Notion case](https://app.notion.com/p/404ead9eb8a881e58e3fdbb842a31d28)

**Doctor cannot see billing** · P0 · security · Role: doctor

- Preconditions: —
- Steps: Open /billing/bills
- Test data: —
- Expected: Blocked; menu hidden
- Rule / code: `permissions.ts doctor has no billing.view`

## DOC-005

[Notion case](https://app.notion.com/p/404ead9eb8a881e8902dffa5d18beffb)

**Doctor marks own no-show only** · P2 · security · Role: doctor

- Preconditions: Another doctor's appt
- Steps: Mark no-show
- Test data: —
- Expected: Denied
- Rule / code: `permissions.ts appointments.no_show_own`
