# Advances test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## ADV-001

[Notion case](https://app.notion.com/p/404ead9eb8a881ad8523ff2ac23c7320)

**Take advance and apply to bill** · P1 · happy · Role: billing

- Preconditions: Patient
- Steps: Take advance ₹1000; apply to bill ₹500
- Test data: —
- Expected: Bill paid; ₹500 remaining advance
- Rule / code: `billing_commands.sql (kind advance)`

## ADV-002

[Notion case](https://app.notion.com/p/404ead9eb8a88117ab02efeb00ca8f94)

**Advance application outside due** · P2 · negative · Role: billing

- Preconditions: Due ₹500
- Steps: Apply ₹600
- Test data: —
- Expected: "advance application is outside the amount due"
- Rule / code: `billing_commands.sql`

## ADV-003

[Notion case](https://app.notion.com/p/404ead9eb8a881bfb48bf120e4339580)

**Advance to closed/cancelled bill** · P2 · negative · Role: billing

- Preconditions: Cancelled bill
- Steps: Apply advance
- Test data: —
- Expected: "an advance applies to an open or finalized bill"
- Rule / code: `billing_commands.sql`

## ADV-004

[Notion case](https://app.notion.com/p/404ead9eb8a88109a6b2eadb06fadec0)

**Advance for different patient** · P1 · data-integrity · Role: billing

- Preconditions: Bill patient B
- Steps: Apply A's advance
- Test data: —
- Expected: "allocations apply to an open or finalized bill for the same patient"
- Rule / code: `billing_commands.sql`
