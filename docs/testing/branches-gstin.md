# Branches & GSTIN test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## BRN-001

[Notion case](https://app.notion.com/p/404ead9eb8a881028e96f2d3f346fa0f)

**Add branch with valid GSTIN** · P0 · happy · Role: tenant_admin

- Preconditions: Admin
- Steps: Admin > Branches > add branch with state and GSTIN
- Test data: Synthetic 15-char GSTIN matching state
- Expected: Branch saved, GSTIN shown on its bills
- Rule / code: `20261025240200_billing_gst_refunds.sql; AppShell admin.branches`

## BRN-002

[Notion case](https://app.notion.com/p/404ead9eb8a8819e84c4f6acfc2c3e3e)

**GSTIN length validation** · P1 · negative · Role: tenant_admin

- Preconditions: —
- Steps: Save GSTIN of 14 and 16 chars
- Test data: —
- Expected: "GSTIN must be 15 characters"
- Rule / code: `billing_gst_refunds.sql`

## BRN-003

[Notion case](https://app.notion.com/p/404ead9eb8a8815e855ffcf31b3072b4)

**Reception cannot manage branches** · P1 · security · Role: receptionist

- Preconditions: —
- Steps: Open /admin/branches
- Test data: —
- Expected: Route hidden/blocked (RequireCapability admin.branches); API 403
- Rule / code: `App.tsx:229; permissions.ts branches.manage`

## BRN-004

[Notion case](https://app.notion.com/p/404ead9eb8a88193a512e76b08ef91b0)

**Delete branch with open appointments blocked** · P1 · data-integrity · Role: tenant_admin

- Preconditions: Branch has booked appointment
- Steps: Delete branch
- Test data: —
- Expected: "branch has open appointments or queue entries"
- Rule / code: `business rules migrations (branch delete)`

## BRN-005

[Notion case](https://app.notion.com/p/404ead9eb8a881f78eadf2bccd4d2b56)

**Restore deleted branch admin-only** · P2 · happy · Role: tenant_admin

- Preconditions: Soft-deleted branch
- Steps: Restore
- Test data: —
- Expected: Restored; non-admin gets "only tenant admins can restore branches"; restoring live branch "branch is not deleted"
- Rule / code: `20261020140000_business_rules.sql`

## BRN-006

[Notion case](https://app.notion.com/p/404ead9eb8a881c8a71fd6bdb9b1ffcd)

**Branch time zone override** · P1 · edge · Role: tenant_admin

- Preconditions: Branch with override e.g. Asia/Dubai
- Steps: Book & check-in at that branch
- Test data: —
- Expected: "Today" for queue and cash limit uses branch zone, not hospital zone
- Rule / code: `20261025220100_scheduling_queue_day_end_close.sql; billing_commands.sql (branch-local day)`

## BRN-007

[Notion case](https://app.notion.com/p/404ead9eb8a881a3afa1c0a713c4b0e6)

**Place of supply must be 2-digit state code** · P2 · negative · Role: billing

- Preconditions: Draft bill
- Steps: Set place of supply "TS"
- Test data: TS
- Expected: "place of supply must be a 2-digit state code"
- Rule / code: `billing_gst_refunds.sql`
