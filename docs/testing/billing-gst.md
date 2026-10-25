# Billing & GST test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## BIL-001

[Notion case](https://app.notion.com/p/404ead9eb8a881a2bf6fcf57134a2de8)

**Intra-state bill splits CGST/SGST** · P0 · happy · Role: billing

- Preconditions: Branch state = place of supply; taxable line 18%
- Steps: Finalize bill
- Test data: ₹100 taxable line
- Expected: CGST 9% + SGST 9%; odd paise to CGST
- Rule / code: `billing.tax_split (billing_gst_refunds.sql:85-110)`

## BIL-002

[Notion case](https://app.notion.com/p/404ead9eb8a881dd90c6cf2c5fab4a51)

**Inter-state bill uses IGST** · P0 · happy · Role: billing

- Preconditions: Place of supply different state
- Steps: Set place of supply on draft; finalize
- Test data: —
- Expected: All tax on IGST, CGST/SGST 0
- Rule / code: `billing.tax_split`

## BIL-003

[Notion case](https://app.notion.com/p/404ead9eb8a8818994a5d7a61e7db34e)

**Missing place of supply treated as intra-state** · P1 · edge · Role: billing

- Preconditions: No place of supply
- Steps: Finalize
- Test data: —
- Expected: CGST/SGST, never IGST
- Rule / code: `billing.tax_split comment`

## BIL-004

[Notion case](https://app.notion.com/p/404ead9eb8a88162aa3af431e35fa24d)

**Healthcare consult exempt (SAC 9993)** · P0 · happy · Role: billing

- Preconditions: Consult line
- Steps: Finalize
- Test data: —
- Expected: Zero GST on consult line; shown as exempt
- Rule / code: `20261023120400_billing_op_v1.sql is_exempt comment`

## BIL-005

[Notion case](https://app.notion.com/p/404ead9eb8a8817496b6d36bdc014ed2)

**Multi-line odd paise rounding** · P2 · edge · Role: billing

- Preconditions: 3 lines each with odd tax paise
- Steps: Finalize
- Test data: —
- Expected: Bill tax = sum of line splits, no re-split
- Rule / code: `tax_split comment`

## BIL-006

[Notion case](https://app.notion.com/p/404ead9eb8a8817f938cc9c887f9c89e)

**Place of supply set only on draft** · P2 · negative · Role: billing

- Preconditions: Finalized bill
- Steps: Change place of supply
- Test data: —
- Expected: "place of supply is set on a draft bill"
- Rule / code: `billing_gst_refunds.sql`

## BIL-007

[Notion case](https://app.notion.com/p/404ead9eb8a881249d82cd620153c45b)

**Finalized bill immutable** · P0 · data-integrity · Role: billing

- Preconditions: Finalized bill
- Steps: Edit a line
- Test data: —
- Expected: "finalized bills are immutable; issue a credit note"
- Rule / code: `billing_op_v1.sql`

## BIL-008

[Notion case](https://app.notion.com/p/404ead9eb8a88142ac29d823ad1a9d95)

**Bill needs a line** · P2 · negative · Role: billing

- Preconditions: Empty draft
- Steps: Finalize
- Test data: —
- Expected: "a bill needs at least one line"
- Rule / code: `billing commands`

## BIL-009

[Notion case](https://app.notion.com/p/404ead9eb8a8811a8857fe5b24273aad)

**Only draft accepts lines/remove/cancel** · P2 · negative · Role: billing

- Preconditions: Finalized bill
- Steps: Add line; remove line; cancel
- Test data: —
- Expected: "only a draft bill accepts lines"/"only a draft line can be removed"/"only a draft bill can be cancelled"
- Rule / code: `billing_commands.sql`

## BIL-010

[Notion case](https://app.notion.com/p/404ead9eb8a881f49234c33a37ca56e0)

**Paid bill cannot be cancelled** · P1 · negative · Role: billing

- Preconditions: Bill with payment
- Steps: Cancel
- Test data: —
- Expected: "a bill with a payment cannot be cancelled; refund the receipt"
- Rule / code: `billing_commands.sql`

## BIL-011

[Notion case](https://app.notion.com/p/404ead9eb8a881809e29e92acafee5e0)

**Service codes server-assigned** · P3 · security · Role: billing

- Preconditions: —
- Steps: Send serviceCode in request
- Test data: —
- Expected: "Service codes are assigned by the server and cannot be supplied."
- Rule / code: `20261023150000_billing_server_service_codes.sql`

## BIL-012

[Notion case](https://app.notion.com/p/404ead9eb8a881c48204e76696279c8d)

**No price on date** · P2 · negative · Role: billing

- Preconditions: Service without price on bill date
- Steps: Add line
- Test data: —
- Expected: "no price for this service on this date"
- Rule / code: `billing_price_catalog.sql`

## BIL-013

[Notion case](https://app.notion.com/p/404ead9eb8a881a08d8fc15b7b945606)

**Negative money / qty 0** · P2 · boundary · Role: billing

- Preconditions: —
- Steps: Line qty 0, price -1
- Test data: —
- Expected: "money cannot be negative and quantity must be at least 1"
- Rule / code: `billing_op_v1.sql`

## BIL-014

[Notion case](https://app.notion.com/p/404ead9eb8a881ddabdbe85910fa48c6)

**Discount request and approval** · P1 · happy · Role: receptionist

- Preconditions: Draft bill
- Steps: Request discount; admin approves
- Test data: —
- Expected: Applied after approval; requester cannot approve own
- Rule / code: `billing_gst_refunds.sql ("You requested this...")`

## BIL-015

[Notion case](https://app.notion.com/p/404ead9eb8a8817da43af99ffcbb6a89)

**Discount only on draft and within bill** · P2 · negative · Role: billing

- Preconditions: —
- Steps: Discount on finalized; discount > total
- Test data: —
- Expected: "discounts are requested on a draft bill"; "discount is outside the bill"
- Rule / code: `billing_commands.sql`

## BIL-016

[Notion case](https://app.notion.com/p/404ead9eb8a881f7a596fa8912fa2b75)

**Nurse/doctor cannot bill** · P1 · security · Role: nurse

- Preconditions: —
- Steps: Open bills
- Test data: —
- Expected: Hidden/denied
- Rule / code: `permissions.ts`

## BIL-017

[Notion case](https://app.notion.com/p/404ead9eb8a881aea709d8512956e2bc)

**Draft bill display label** · P2 · edge · Role: billing

- Preconditions: Draft bill
- Steps: View list
- Test data: —
- Expected: Known issue: shows "Draft draft", no number
- Rule / code: `User manual gap`

## BIL-018

[Notion case](https://app.notion.com/p/404ead9eb8a881eaa9eef1d6160b54c1)

**Document number length** · P3 · boundary · Role: billing

- Preconditions: Long prefix
- Steps: Finalize
- Test data: —
- Expected: "prefix must be 1 to 4 letters or digits"; number ≤16
- Rule / code: `billing_op_v1.sql`
