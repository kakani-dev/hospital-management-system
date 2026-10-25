# Time zones test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## TZ-001

[Notion case](https://app.notion.com/p/404ead9eb8a88178a279db1bb2a38d38)

**Today at 23:59 vs 00:01 IST** · P0 · edge · Role: receptionist

- Preconditions: Hospital Asia/Kolkata
- Steps: Book at 23:59; at 00:01 check-in old
- Test data: —
- Expected: Day boundaries in IST, not UTC (05:30 offset)
- Rule / code: `tenant_time_zone.sql; opd_queue.sql`

## TZ-002

[Notion case](https://app.notion.com/p/404ead9eb8a88173b9e1c538bef9aff9)

**Branch override zone** · P1 · edge · Role: receptionist

- Preconditions: Branch Asia/Dubai
- Steps: Check-in/queue close near Dubai midnight
- Test data: —
- Expected: Uses branch zone
- Rule / code: `scheduling_queue_day_end_close.sql`

## TZ-003

[Notion case](https://app.notion.com/p/404ead9eb8a8810992cbfab378c82a00)

**Only admins change time zone** · P2 · security · Role: receptionist

- Preconditions: —
- Steps: Change time zone
- Test data: —
- Expected: "only tenant admins can change the time zone"
- Rule / code: `tenant_time_zone.sql`

## TZ-004

[Notion case](https://app.notion.com/p/404ead9eb8a8812ea19ef871e8d11844)

**Cash limit resets at branch-local midnight** · P2 · edge · Role: billing

- Preconditions: Patient near limit
- Steps: Pay after midnight
- Test data: —
- Expected: Allowed next local day
- Rule / code: `billing_commands.sql:381`
