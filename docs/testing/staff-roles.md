# Staff & roles test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## STF-001

[Notion case](https://app.notion.com/p/404ead9eb8a8812db967c9d9d630c7c9)

**Admin invites staff by email** · P0 · happy · Role: tenant_admin

- Preconditions: —
- Steps: Admin > Members > invite as receptionist
- Test data: Synthetic email
- Expected: Invite sent; appears in list as invited
- Rule / code: `20261020140000_business_rules.sql; App.tsx /invite/:token`

## STF-002

[Notion case](https://app.notion.com/p/404ead9eb8a881338fc8d9411f746353)

**Invite accepted only by invitee** · P1 · security · Role: receptionist

- Preconditions: Invite for A
- Steps: Log in as B and open A's invite link
- Test data: —
- Expected: "invite_email_mismatch: this invite is for a different email address"
- Rule / code: `invite functions`

## STF-003

[Notion case](https://app.notion.com/p/404ead9eb8a8819c8005cd4711a33d17)

**Expired or used invite** · P2 · negative · Role: anonymous

- Preconditions: Used invite link
- Steps: Open again
- Test data: —
- Expected: "invite not found, expired or already used"
- Rule / code: `invite functions`

## STF-004

[Notion case](https://app.notion.com/p/404ead9eb8a88160af9dda36061f3cb9)

**Cannot remove the last active admin** · P0 · data-integrity · Role: tenant_admin

- Preconditions: Only one admin
- Steps: Remove/suspend self
- Test data: —
- Expected: "last_admin: a hospital must keep at least one active admin"
- Rule / code: `20261020140000_business_rules.sql; 20261025220200_identity_last_admin_soft_delete.sql`

## STF-005

[Notion case](https://app.notion.com/p/404ead9eb8a8812e9d25c1094d8de401)

**Suspended member blocked** · P1 · security · Role: receptionist

- Preconditions: Admin suspended this member
- Steps: Log in and open any page
- Test data: —
- Expected: "Your membership in this hospital is suspended. Ask a hospital admin."
- Rule / code: `identity membership guard`

## STF-006

[Notion case](https://app.notion.com/p/404ead9eb8a881a7accec8c4b493f6bc)

**Only admins add/remove/restore members** · P1 · security · Role: receptionist

- Preconditions: —
- Steps: Try /admin/members
- Test data: —
- Expected: Route blocked; API "only tenant admins can add members"
- Rule / code: `App.tsx:230; permissions.ts members.manage`

## STF-007

[Notion case](https://app.notion.com/p/404ead9eb8a88156a8eef7f6f810f581)

**Role matrix: menus per role** · P0 · security · Role: all roles

- Preconditions: One login per role
- Steps: Log in as each role; list sidebar items
- Test data: —
- Expected: Menus exactly match ROLE_PERMISSIONS (e.g., accountant sees only earnings + read-only ops)
- Rule / code: `permissions.ts ROLE_PERMISSIONS; AppShell.tsx`

## STF-008

[Notion case](https://app.notion.com/p/404ead9eb8a881eba3e4f591fbd503b4)

**Membership cannot go back to invited** · P3 · negative · Role: tenant_admin

- Preconditions: Active membership
- Steps: Try set status invited
- Test data: —
- Expected: "a membership cannot be moved back to invited"
- Rule / code: `identity migrations`

## STF-009

[Notion case](https://app.notion.com/p/404ead9eb8a881008885c85a41b114f6)

**Practitioner delete with open appointments** · P2 · data-integrity · Role: tenant_admin

- Preconditions: Doctor with future booking
- Steps: Delete practitioner
- Test data: —
- Expected: "practitioner has open appointments"
- Rule / code: `business rules`
