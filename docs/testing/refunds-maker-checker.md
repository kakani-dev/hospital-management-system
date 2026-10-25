# Refunds & maker-checker test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## REF-001

[Notion case](https://app.notion.com/p/404ead9eb8a88173a7dddd728978d2b9)

**Small refund ≤ ₹200 no approval** · P0 · happy · Role: billing

- Preconditions: Paid receipt
- Steps: Refund ₹200
- Test data: —
- Expected: Refund completes immediately (threshold strictly above)
- Rule / code: `billing_gst_refunds.sql:54-67 maker_checker_threshold_paise 20000`

## REF-002

[Notion case](https://app.notion.com/p/404ead9eb8a881e8a407ed08d4fb9688)

**Refund ₹200.01 needs a different approver** · P0 · security · Role: billing

- Preconditions: Paid receipt
- Steps: Refund ₹200.01; same user tries approve
- Test data: —
- Expected: Pending approval; "You requested this, so someone else must approve it."
- Rule / code: `billing_gst_refunds.sql`

## REF-003

[Notion case](https://app.notion.com/p/404ead9eb8a8816c83eaeef8c54c4335)

**Admin approves refund** · P0 · happy · Role: tenant_admin

- Preconditions: REF-002 pending
- Steps: Billing > Approvals approve
- Test data: —
- Expected: Refund done; approval decided; re-approve "approval is already decided"
- Rule / code: `App.tsx billing/approvals; billing_gst_refunds.sql`

## REF-004

[Notion case](https://app.notion.com/p/404ead9eb8a881ac855bd381f13b2d10)

**Refund exceeds refundable** · P1 · negative · Role: billing

- Preconditions: ₹500 paid, ₹300 refunded
- Steps: Refund ₹300
- Test data: —
- Expected: "refund exceeds the amount still refundable"
- Rule / code: `billing_commands.sql`

## REF-005

[Notion case](https://app.notion.com/p/404ead9eb8a8819fa329d3d8ecba824d)

**Refund of a refund** · P2 · negative · Role: billing

- Preconditions: —
- Steps: Refund the refund receipt
- Test data: —
- Expected: "a refund cannot be refunded"
- Rule / code: `billing_commands.sql`

## REF-006

[Notion case](https://app.notion.com/p/404ead9eb8a8810da41dedda7991238f)

**Cash refund needs open session** · P1 · negative · Role: billing

- Preconditions: No session
- Steps: Cash refund
- Test data: —
- Expected: "a cash refund needs an open counter session"
- Rule / code: `billing_open_bill_payments.sql`

## REF-007

[Notion case](https://app.notion.com/p/404ead9eb8a88138bab4ce33d295c92d)

**Cash refund of digital payment needs manager** · P1 · security · Role: billing

- Preconditions: UPI receipt
- Steps: Refund in cash as billing
- Test data: —
- Expected: "a cash refund of a digital payment needs a manager"
- Rule / code: `billing_gst_refunds.sql`

## REF-008

[Notion case](https://app.notion.com/p/404ead9eb8a8816abebfe1f8446663b0)

**Threshold settings** · P2 · boundary · Role: tenant_admin

- Preconditions: —
- Steps: Set threshold -1, 0
- Test data: —
- Expected: -1 "maker-checker threshold must be zero or more"; 0 → every refund needs approval
- Rule / code: `billing_gst_refunds.sql:275-301`

## REF-009

[Notion case](https://app.notion.com/p/404ead9eb8a8814ba091d18a1fc44138)

**Approval limit** · P2 · security · Role: billing

- Preconditions: Approver with limit
- Steps: Approve above limit
- Test data: —
- Expected: "outside your approval limit"
- Rule / code: `billing_gst_refunds.sql`

## REF-010

[Notion case](https://app.notion.com/p/404ead9eb8a88120be08f4db11faf051)

**Refund Button visible** · P2 · edge · Role: billing

- Preconditions: Paid receipt
- Steps: Look for Refund
- Test data: —
- Expected: Check #81 status
- Rule / code: `GitHub #81`

## REF-011

[Notion case](https://app.notion.com/p/404ead9eb8a881699451e99427c8913b)

**Two approvers at once** · P1 · concurrency · Role: tenant_admin

- Preconditions: Pending approval
- Steps: Two admins approve simultaneously
- Test data: —
- Expected: One wins; other "approval is already decided"
- Rule / code: `billing_gst_refunds.sql`

## REF-012

[Notion case](https://app.notion.com/p/404ead9eb8a88102aa79d729cc180564)

**Cancel/no-show refund percent** · P3 · boundary · Role: tenant_admin

- Preconditions: Settings
- Steps: Set 10001 bp
- Test data: —
- Expected: "cancel refund percent must be between 0 and 10000"
- Rule / code: `billing_gst_refunds.sql`
