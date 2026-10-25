# Tenant signup test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## SIG-001

[Notion case](https://app.notion.com/p/404ead9eb8a8817387d7e084369c8dbf)

**New hospital self-registers** · P0 · happy · Role: anonymous

- Preconditions: Fresh email not used anywhere
- Steps: Open /register-hospital; fill hospital name, time zone, contact, email; submit
- Test data: Synthetic hospital "QA Test Hospital <date>", qa+<date>@example.test
- Expected: Request accepted and shown as pending for platform approval
- Rule / code: `PlatformEndpoints.cs signup; 20261019090000_level1_platform_onboarding.sql`

## SIG-002

[Notion case](https://app.notion.com/p/404ead9eb8a881e293f2d1ed94ba6bea)

**Repeat signup with an already-registered email is blocked** · P0 · negative · Role: anonymous

- Preconditions: Email already belongs to an approved hospital or a user
- Steps: Submit /register-hospital with that email
- Test data: Email of an existing demo admin (from Mohith's private sheet)
- Expected: HTTP 409, problem code "email_registered"; no new request row
- Rule / code: `PlatformEndpoints.cs:126; identity_signup_duplicate_guard.sql (email_already_registered)`

## SIG-003

[Notion case](https://app.notion.com/p/404ead9eb8a88134ae11d73e77c492a5)

**Email match is case- and space-insensitive** · P1 · edge · Role: anonymous

- Preconditions: SIG-002 email known
- Steps: Submit with the same email in UPPER case with leading/trailing spaces
- Test data: "  DEMO.Admin@... "
- Expected: Still 409 email_registered
- Rule / code: `identity_signup_duplicate_guard.sql lower(btrim(email)) trigger line ~197`

## SIG-004

[Notion case](https://app.notion.com/p/404ead9eb8a88150a4b0cd38f7a76bde)

**Similar hospital name flags possible duplicate** · P1 · data-integrity · Role: platform admin

- Preconditions: A pending request whose name differs only by case/punctuation from an existing hospital
- Steps: Open Platform > Requests; try Approve
- Test data: Name "Medicore-Demo Hospital!"
- Expected: Request marked possible_duplicate with matched hospitals; approve without confirm returns 409 possible_duplicate
- Rule / code: `identity_signup_duplicate_guard.sql (normalised name regexp); PlatformEndpoints.cs:206`

## SIG-005

[Notion case](https://app.notion.com/p/404ead9eb8a8818f87b3c05d76ff8e60)

**Approve possible duplicate after explicit confirm** · P2 · happy · Role: platform admin

- Preconditions: SIG-004 state
- Steps: Approve with the confirm step
- Test data: —
- Expected: Tenant created; request approved
- Rule / code: `PlatformEndpoints.cs approve; identity_signup_duplicate_guard.sql`

## SIG-006

[Notion case](https://app.notion.com/p/404ead9eb8a88102839be78afb57ce02)

**Registration rate limit** · P2 · security · Role: anonymous

- Preconditions: —
- Steps: Submit many registrations from one source quickly
- Test data: Synthetic emails
- Expected: Eventually rejected with "rate_limited: too many hospital registrations from this source" (429)
- Rule / code: `20261019090000_level1_platform_onboarding.sql`

## SIG-007

[Notion case](https://app.notion.com/p/404ead9eb8a881419cbbd64b1f53c8c0)

**Invalid admin email rejected** · P2 · negative · Role: anonymous

- Preconditions: —
- Steps: Submit with "abc@" as email
- Test data: abc@
- Expected: 400 "adminEmail: a valid email is required"
- Rule / code: `level1_platform_onboarding.sql`

## SIG-008

[Notion case](https://app.notion.com/p/404ead9eb8a8814fad60f06b606371fe)

**Non-platform admin cannot create tenants** · P1 · security · Role: tenant_admin

- Preconditions: Logged in as hospital admin
- Steps: Call platform create tenant / open /platform
- Test data: —
- Expected: /platform blocked by RequirePlatformAdmin; API 403 "only platform admins can create tenants"
- Rule / code: `App.tsx RequirePlatformAdmin; level1_platform_onboarding.sql`

## SIG-009

[Notion case](https://app.notion.com/p/404ead9eb8a881768bf3d2d8c6493c16)

**Double-click submit creates one request** · P2 · concurrency · Role: anonymous

- Preconditions: —
- Steps: Double-click Submit on registration
- Test data: Synthetic
- Expected: Only one request row; second gets 409 or same result
- Rule / code: `identity_signup_duplicate_guard.sql`
