# Setup wizard test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## WIZ-001

[Notion case](https://app.notion.com/p/404ead9eb8a881778f18e130a50ef764)

**First admin completes setup wizard** · P0 · happy · Role: tenant_admin

- Preconditions: Newly approved hospital
- Steps: Log in; /setup opens; complete hospital, branch, staff steps
- Test data: Branch "QA Main", state code 36
- Expected: Wizard completes and lands on home
- Rule / code: `20261025200000_identity_setup_wizard.sql; App.tsx route setup`

## WIZ-002

[Notion case](https://app.notion.com/p/404ead9eb8a8818db678d2f112df97d8)

**Cannot leave branch step without a live branch** · P1 · negative · Role: tenant_admin

- Preconditions: Wizard at branch step, no branch
- Steps: Click Next
- Test data: —
- Expected: Error "a live branch is required before leaving the branch step"
- Rule / code: `identity_setup_wizard.sql`

## WIZ-003

[Notion case](https://app.notion.com/p/404ead9eb8a8814eaddbf491313ea985)

**Non-admin cannot read or change setup** · P1 · security · Role: receptionist

- Preconditions: Reception login
- Steps: Open /setup
- Test data: —
- Expected: Blocked; API "only tenant admins can read setup" / "can change setup"
- Rule / code: `identity_setup_wizard.sql`

## WIZ-004

[Notion case](https://app.notion.com/p/404ead9eb8a88139a3d5d04cfbcf545b)

**Legal name length boundary** · P3 · edge · Role: tenant_admin

- Preconditions: Wizard hospital step
- Steps: Enter 200 then 201 chars
- Test data: 201-char string
- Expected: 200 ok; 201 rejected "legal name must be 200 characters or fewer"
- Rule / code: `identity_setup_wizard.sql`

## WIZ-005

[Notion case](https://app.notion.com/p/404ead9eb8a8818aa254ff9d1fd47089)

**Hospital time zone must be valid IANA** · P1 · negative · Role: tenant_admin

- Preconditions: Wizard/hospital settings
- Steps: Set time zone "India/Mumbai"
- Test data: India/Mumbai
- Expected: "invalid_time_zone: India/Mumbai is not a known IANA time zone"
- Rule / code: `20261012090100_tenant_time_zone.sql`
