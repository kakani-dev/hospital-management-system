# Privacy & DPDP test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## PRV-001

[Notion case](https://app.notion.com/p/404ead9eb8a881939794f455b52cb5a0)

**Consent captured at registration** · P0 · happy · Role: receptionist

- Preconditions: —
- Steps: Register patient with consent
- Test data: —
- Expected: Consent event recorded
- Rule / code: `20261025220500_privacy_foundation.sql`

## PRV-002

[Notion case](https://app.notion.com/p/404ead9eb8a881c79815c10883fc94cf)

**Consent events append-only** · P1 · security · Role: tenant_admin

- Preconditions: —
- Steps: Update consent event via API
- Test data: —
- Expected: "consent_event is append-only"
- Rule / code: `privacy_foundation.sql`

## PRV-003

[Notion case](https://app.notion.com/p/404ead9eb8a88180909efce8fe34cb5b)

**Public consent link** · P1 · security · Role: anonymous

- Preconditions: Token
- Steps: Open /privacy/consent/<token>
- Test data: —
- Expected: Shows notice; invalid "link not found"
- Rule / code: `App.tsx PublicConsentPage`

## PRV-004

[Notion case](https://app.notion.com/p/404ead9eb8a8814eb73dc63bc269dca8)

**Rights request lifecycle** · P1 · happy · Role: receptionist

- Preconditions: —
- Steps: Raise access request; admin fulfils
- Test data: —
- Expected: Statuses; second decision "This request was already %."
- Rule / code: `privacy_foundation.sql`

## PRV-005

[Notion case](https://app.notion.com/p/404ead9eb8a881078d91fbe5b5d76ef9)

**Erase permission admin-only** · P1 · security · Role: receptionist

- Preconditions: —
- Steps: Erase patient data
- Test data: —
- Expected: Denied (privacy.erase)
- Rule / code: `permissions.ts`

## PRV-006

[Notion case](https://app.notion.com/p/404ead9eb8a8813d8f19f32dbe077b83)

**Notices admin-only** · P2 · security · Role: receptionist

- Preconditions: —
- Steps: Open /admin/privacy-notices
- Test data: —
- Expected: Blocked
- Rule / code: `App.tsx:272`

## PRV-007

[Notion case](https://app.notion.com/p/404ead9eb8a881ac8583c4c8df930f82)

**Rights request events append-only** · P2 · security · Role: tenant_admin

- Preconditions: —
- Steps: Edit event
- Test data: —
- Expected: "rights_request_event is append-only"
- Rule / code: `privacy_foundation.sql`

## PRV-008

[Notion case](https://app.notion.com/p/404ead9eb8a88146ac84fed1e0248848)

**Data requests menu location** · P3 · edge · Role: receptionist

- Preconditions: —
- Steps: Look for Data requests
- Test data: —
- Expected: Known gap: under Pharmacy menu
- Rule / code: `User manual gap`

## PRV-009

[Notion case](https://app.notion.com/p/404ead9eb8a881f39e23e11a7bd92b89)

**Reason length** · P3 · boundary · Role: tenant_admin

- Preconditions: —
- Steps: Reason 2 chars, 501 chars
- Test data: —
- Expected: "reason: give a reason of 3-500 characters"
- Rule / code: `privacy_foundation.sql`
