# Credit notes test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## CRN-001

[Notion case](https://app.notion.com/p/404ead9eb8a881c79a03d50b1eefcde5)

**Credit note on finalized bill line** · P1 · happy · Role: billing

- Preconditions: Finalized bill
- Steps: Issue credit note qty 1
- Test data: —
- Expected: Negative lines; GST reversed by same split
- Rule / code: `billing_gst_refunds.sql`

## CRN-002

[Notion case](https://app.notion.com/p/404ead9eb8a881198338ecf58a649407)

**Credit over original qty** · P1 · negative · Role: billing

- Preconditions: Line qty 2, 1 credited
- Steps: Credit 2
- Test data: —
- Expected: "credit quantity exceeds the amount not already credited"
- Rule / code: `billing_gst_refunds.sql`

## CRN-003

[Notion case](https://app.notion.com/p/404ead9eb8a88147802ecd377f9c4450)

**Credit note needs a line** · P3 · negative · Role: billing

- Preconditions: —
- Steps: Empty credit note
- Test data: —
- Expected: "a credit note needs a line"
- Rule / code: `billing_gst_refunds.sql`

## CRN-004

[Notion case](https://app.notion.com/p/404ead9eb8a881b6a768db8acd2fa81a)

**Paid line locked** · P2 · negative · Role: billing

- Preconditions: Paid line on draft
- Steps: Remove line
- Test data: —
- Expected: "a paid line is locked; refund the receipt or issue a credit note"
- Rule / code: `billing_open_bill_payments.sql`
