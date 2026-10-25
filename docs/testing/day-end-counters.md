# Day-end & counters test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## DAY-001

[Notion case](https://app.notion.com/p/404ead9eb8a8818c935fd05f3e69575f)

**Open counter session** · P0 · happy · Role: billing

- Preconditions: Signed in cashier
- Steps: Day-end > open session
- Test data: —
- Expected: Session open
- Rule / code: `billing_commands.sql`

## DAY-002

[Notion case](https://app.notion.com/p/404ead9eb8a88141a650f82820bd5a9b)

**Close session with matching cash** · P0 · happy · Role: billing

- Preconditions: Open session with cash taken
- Steps: Count cash = expected
- Test data: —
- Expected: Closed; expected cash includes refunds
- Rule / code: `20261025220400_billing_day_end_expected_cash.sql`

## DAY-003

[Notion case](https://app.notion.com/p/404ead9eb8a88139b291fd01e9943e20)

**Cash variance needs approved override** · P1 · negative · Role: billing

- Preconditions: Counted ≠ expected
- Steps: Close
- Test data: —
- Expected: "a cash variance needs an approved override"
- Rule / code: `billing_commands.sql`

## DAY-004

[Notion case](https://app.notion.com/p/404ead9eb8a881978d2aea6c7b7a2be7)

**Closed session immutable** · P1 · data-integrity · Role: billing

- Preconditions: Closed
- Steps: Add payment
- Test data: —
- Expected: "a closed counter session cannot be changed"
- Rule / code: `billing_commands.sql`

## DAY-005

[Notion case](https://app.notion.com/p/404ead9eb8a88197843adbcd36d40484)

**Counter close UI missing** · P1 · edge · Role: billing

- Preconditions: —
- Steps: Find close-counter/count-cash screen
- Test data: —
- Expected: Known gap: no screen
- Rule / code: `User manual gap`

## DAY-006

[Notion case](https://app.notion.com/p/404ead9eb8a8815c971fe9ec0433dc0c)

**Reconcile permission** · P2 · security · Role: receptionist

- Preconditions: —
- Steps: Reconcile counter
- Test data: —
- Expected: Denied (billing.counter_reconcile only admin)
- Rule / code: `permissions.ts`
