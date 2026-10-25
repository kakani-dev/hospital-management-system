# Outbox & webhooks test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## OUT-001

[Notion case](https://app.notion.com/p/404ead9eb8a881ce9124cb9437657973)

**Outbox event dispatched** · P1 · happy · Role: tenant_admin

- Preconditions: Dispatcher on
- Steps: Book appointment
- Test data: —
- Expected: Outbox row delivered
- Rule / code: `20261025210000_platform_outbox_dispatcher.sql`

## OUT-002

[Notion case](https://app.notion.com/p/404ead9eb8a881e1a3bbce78e2df8218)

**Dead letter after 10 attempts** · P2 · edge · Role: platform admin

- Preconditions: Failing consumer
- Steps: Observe row
- Test data: —
- Expected: status dead after attempts >= 10
- Rule / code: `platform_outbox_dispatcher.sql:57-66`

## OUT-003

[Notion case](https://app.notion.com/p/404ead9eb8a881e69a11c8619517fcdf)

**Webhook duplicate event ignored** · P1 · concurrency · Role: platform admin

- Preconditions: Payment provider event
- Steps: Replay same event id
- Test data: —
- Expected: Stored once
- Rule / code: `20261025210100_billing_webhook_guard.sql`

## OUT-004

[Notion case](https://app.notion.com/p/404ead9eb8a881e0aae6e4cd53f6e952)

**Webhook requires ids** · P2 · negative · Role: platform admin

- Preconditions: —
- Steps: Webhook without eventId
- Test data: —
- Expected: "eventId and providerOrderId are required"
- Rule / code: `billing_webhook_guard.sql`

## OUT-005

[Notion case](https://app.notion.com/p/404ead9eb8a88166a251e21c28b21f34)

**Lease bounds** · P3 · boundary · Role: platform admin

- Preconditions: —
- Steps: Claim with lease 2h
- Test data: —
- Expected: "lease must be > 0 and <= 1 hour"
- Rule / code: `platform_outbox_dispatcher.sql`
