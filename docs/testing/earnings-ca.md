# Earnings & CA test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## EAR-001

[Notion case](https://app.notion.com/p/404ead9eb8a881d8b89be74a46162607)

**Earnings totals reconcile with bills** · P0 · data-integrity · Role: accountant

- Preconditions: Demo bills for a day
- Steps: Compare earnings day total vs sum of finalized bills minus refunds/credit notes
- Test data: —
- Expected: Totals match to the paisa
- Rule / code: `20261025250300_billing_earnings.sql`

## EAR-002

[Notion case](https://app.notion.com/p/404ead9eb8a881678101f1c28e7d7f29)

**Branch-wise vs tenant-wide** · P1 · data-integrity · Role: tenant_admin

- Preconditions: 3 branches
- Steps: Sum branch earnings
- Test data: —
- Expected: Equals tenant total
- Rule / code: `billing_earnings.sql`

## EAR-003

[Notion case](https://app.notion.com/p/404ead9eb8a881b3a5b9f403e5cfd0cf)

**Grain day/week/month** · P2 · boundary · Role: accountant

- Preconditions: —
- Steps: grain=year
- Test data: —
- Expected: "grain must be day, week or month"
- Rule / code: `billing_earnings.sql`

## EAR-004

[Notion case](https://app.notion.com/p/404ead9eb8a881ddbcc2da8f7330313c)

**Quarter and FY validation** · P2 · boundary · Role: accountant

- Preconditions: CA tab
- Steps: Quarter 5; FY 1999
- Test data: —
- Expected: "quarter must be 1, 2, 3 or 4"; "financial year must be between 2000 and 2100"
- Rule / code: `billing_earnings.sql`

## EAR-005

[Notion case](https://app.notion.com/p/404ead9eb8a881aea6c8d846f54acdf5)

**GST summary CGST/SGST/IGST matches bills** · P0 · data-integrity · Role: accountant

- Preconditions: Month with intra and inter bills
- Steps: CA tab GST summary
- Test data: —
- Expected: Matches bills; branch GSTIN shown
- Rule / code: `billing_earnings.sql; known #92`

## EAR-006

[Notion case](https://app.notion.com/p/404ead9eb8a881708b0ec20ca1f1591d)

**Exports file names/format** · P1 · edge · Role: accountant

- Preconditions: —
- Steps: Download each CA export
- Test data: —
- Expected: Known #90: all named earnings.csv
- Rule / code: `GitHub #90`

## EAR-007

[Notion case](https://app.notion.com/p/404ead9eb8a8810f9ae2e72239eb0edc)

**Reception cannot see earnings** · P0 · security · Role: receptionist

- Preconditions: —
- Steps: Open /billing/earnings
- Test data: —
- Expected: Blocked
- Rule / code: `permissions.ts billing.earnings`

## EAR-008

[Notion case](https://app.notion.com/p/404ead9eb8a881f0bc0decd9f3130567)

**Accountant cannot bill or see patients** · P1 · security · Role: accountant

- Preconditions: —
- Steps: Open /patients, /billing/bills
- Test data: —
- Expected: Blocked
- Rule / code: `permissions.ts accountant`

## EAR-009

[Notion case](https://app.notion.com/p/404ead9eb8a881c48c82e37acc047ca6)

**Month boundary IST** · P1 · edge · Role: accountant

- Preconditions: Bill at 23:50 IST on 31st
- Steps: Month report
- Test data: —
- Expected: Bill in month of IST date, not UTC
- Rule / code: `billing_earnings.sql (branch-local)`
