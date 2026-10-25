# Day in the hospital test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## E2E-001

[Notion case](https://app.notion.com/p/404ead9eb8a881d2ab19dbf3dbeaaa3d)

**Morning opening** · P0 · happy · Role: tenant_admin, billing, receptionist

- Preconditions: New day
- Steps: Admin logs in; cashier opens counter session; reception sees today's appointments; doctors see own queue
- Test data: Demo tenant
- Expected: Each role sees right data for IST today
- Rule / code: `AppShell; billing_commands.sql`

## E2E-002

[Notion case](https://app.notion.com/p/404ead9eb8a881a0aaddd5aa0f5f9cd3)

**Busy OPD hour** · P0 · happy · Role: receptionist, doctor, billing

- Preconditions: 10 booked + 3 walk-ins
- Steps: Register walk-ins, check in all, doctors advance, billing collects mixed modes
- Test data: —
- Expected: Queue order sane; each check-in one draft bill; payments match
- Rule / code: `opd_queue.sql; billing_open_bill_payments.sql`

## E2E-003

[Notion case](https://app.notion.com/p/404ead9eb8a881068337c21b555a3eef)

**Refund dispute** · P0 · happy · Role: billing, tenant_admin

- Preconditions: Patient paid ₹500 UPI, disputes
- Steps: Cashier requests ₹500 refund; tries cash; admin approves to UPI
- Test data: —
- Expected: Approval required; cash of digital needs manager; audit trail
- Rule / code: `billing_gst_refunds.sql`

## E2E-004

[Notion case](https://app.notion.com/p/404ead9eb8a881649b41cd9a1e4eddc7)

**Day-end close** · P0 · happy · Role: billing, tenant_admin

- Preconditions: Day of payments
- Steps: Count cash, close session, close queue after midnight
- Test data: —
- Expected: Expected cash matches; variance needs override; queue closes only after day ends
- Rule / code: `day_end_expected_cash.sql; queue_day_end_close.sql`

## E2E-005

[Notion case](https://app.notion.com/p/404ead9eb8a88169b680ef121c807f29)

**CA month-end GST** · P0 · data-integrity · Role: accountant

- Preconditions: Month of bills, refunds, credit notes
- Steps: Run GST summary, registers, exports
- Test data: —
- Expected: Totals reconcile with bill list; IGST only on inter-state
- Rule / code: `billing_earnings.sql`

## E2E-006

[Notion case](https://app.notion.com/p/404ead9eb8a8814f9c4bda1e7a76c6e4)

**New hospital onboarding** · P1 · happy · Role: anonymous, platform admin, tenant_admin

- Preconditions: —
- Steps: Register, approve, wizard, invite staff, first patient
- Test data: Synthetic test hospital (ask Mohith first)
- Expected: Works end-to-end
- Rule / code: `SIG/WIZ refs`
