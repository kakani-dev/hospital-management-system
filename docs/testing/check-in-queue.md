# Check-in & queue test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## QUE-001

[Notion case](https://app.notion.com/p/404ead9eb8a88195a0a3c106f18bd2a1)

**Check-in creates queue entry and draft consult bill** · P0 · happy · Role: receptionist

- Preconditions: Today's booked appt
- Steps: Reception > Check-in
- Test data: —
- Expected: Queue entry waiting; draft bill with consult line at visit fee
- Rule / code: `opd_queue.sql; billing_visit_fee_on_consult_draft.sql`

## QUE-002

[Notion case](https://app.notion.com/p/404ead9eb8a881ad8d49deb557db0721)

**Double check-in** · P0 · concurrency · Role: receptionist

- Preconditions: Already checked in
- Steps: Check in again (two tabs)
- Test data: —
- Expected: "appointment already checked in"; one bill only
- Rule / code: `opd_queue.sql`

## QUE-003

[Notion case](https://app.notion.com/p/404ead9eb8a88125bd2bf2a8234c2cf3)

**Check-in for another day blocked** · P1 · negative · Role: receptionist

- Preconditions: Tomorrow's appt
- Steps: Check in today
- Test data: —
- Expected: "appointment is not for today at this branch"
- Rule / code: `opd_queue.sql`

## QUE-004

[Notion case](https://app.notion.com/p/404ead9eb8a88175b6b4ebc54d0a5ee3)

**One active queue entry per patient per branch per day** · P1 · data-integrity · Role: receptionist

- Preconditions: Patient in queue
- Steps: Add walk-in for same patient
- Test data: —
- Expected: "patient already has an active queue entry at this branch today"
- Rule / code: `20261010090200_opd_queue.sql`

## QUE-005

[Notion case](https://app.notion.com/p/404ead9eb8a88180aef4ea6ed6fa3c4a)

**Doctor advances waiting->in consultation->done** · P0 · happy · Role: doctor

- Preconditions: Own patient waiting
- Steps: Advance status
- Test data: —
- Expected: Statuses move; invalid jumps "invalid_transition:x->y"
- Rule / code: `opd_queue.sql`

## QUE-006

[Notion case](https://app.notion.com/p/404ead9eb8a881dba1eaca98a7dd05a8)

**Check-in not permitted at other branch** · P1 · security · Role: receptionist

- Preconditions: Member of branch 1 only
- Steps: Check in at branch 2
- Test data: —
- Expected: "not permitted to check in at this branch"
- Rule / code: `opd_queue.sql`

## QUE-007

[Notion case](https://app.notion.com/p/404ead9eb8a8817ea8bedc1ccbf5ba7b)

**Queue day close only after day ends** · P1 · edge · Role: receptionist

- Preconditions: Today
- Steps: Close queue day before midnight branch time
- Test data: —
- Expected: "A queue day cannot be closed before it ends in the branch time zone."
- Rule / code: `20261025220100_scheduling_queue_day_end_close.sql`

## QUE-008

[Notion case](https://app.notion.com/p/404ead9eb8a88140815dc49c08243857)

**Only permitted roles close queue** · P2 · security · Role: doctor

- Preconditions: —
- Steps: Close queue
- Test data: —
- Expected: "not permitted to close the queue"
- Rule / code: `queue_day_end_close.sql`

## QUE-009

[Notion case](https://app.notion.com/p/404ead9eb8a8815b9e76ef954ff5a874)

**Accountant has no queue** · P2 · security · Role: accountant

- Preconditions: —
- Steps: Open /queue
- Test data: —
- Expected: Blocked
- Rule / code: `permissions.ts accountant`
