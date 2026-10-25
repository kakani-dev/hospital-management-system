# Resilience & performance test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## NET-001

[Notion case](https://app.notion.com/p/404ead9eb8a881faaec4c3759a6de4e5)

**Cold start first load** · P1 · performance · Role: receptionist

- Preconditions: Idle 15+ min
- Steps: Log in, time first page
- Test data: —
- Expected: Loads; currently ~13.5 s; record time
- Rule / code: `Azure Container Apps scale-to-zero`

## NET-002

[Notion case](https://app.notion.com/p/404ead9eb8a881c9ad6af860b7f34f77)

**Bills page speed** · P2 · performance · Role: billing

- Preconditions: —
- Steps: Open bills
- Test data: —
- Expected: Record time (5-7 s seen)
- Rule / code: `BillsPage`

## NET-003

[Notion case](https://app.notion.com/p/404ead9eb8a8819caa19f77f01b569f3)

**Network drop during payment** · P0 · concurrency · Role: billing

- Preconditions: DevTools offline
- Steps: Pay, go offline, retry
- Test data: —
- Expected: Exactly one payment after retry (idempotency)
- Rule / code: `billing_commands.sql idempotency key`

## NET-004

[Notion case](https://app.notion.com/p/404ead9eb8a8819881c0fad080bc28b1)

**API rate limit 300/min** · P3 · performance · Role: receptionist

- Preconditions: —
- Steps: Hammer list endpoint
- Test data: —
- Expected: 429 beyond 300/min per user; health unlimited
- Rule / code: `EdgeHost.cs:52-60`

## NET-005

[Notion case](https://app.notion.com/p/404ead9eb8a881869e10d8c5cee4da12)

**Warm-up call console error** · P3 · edge · Role: any

- Preconditions: —
- Steps: Watch console
- Test data: —
- Expected: Known #91
- Rule / code: `GitHub #91`

## NET-006

[Notion case](https://app.notion.com/p/404ead9eb8a881fb8611cb2c921a0743)

**Request ID returned** · P2 · happy · Role: any

- Preconditions: —
- Steps: Inspect response headers
- Test data: —
- Expected: X-Request-Id present for triage
- Rule / code: `RequestIdMiddleware.cs`
