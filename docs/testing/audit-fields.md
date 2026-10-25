# Audit fields test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## AUD-001

[Notion case](https://app.notion.com/p/404ead9eb8a88181aec3cc023753ed96)

**Audit fields set on create/update** · P1 · data-integrity · Role: tenant_admin

- Preconditions: —
- Steps: Create and edit a patient; check created_by/updated_by
- Test data: —
- Expected: Set to actor; system actor for system inserts
- Rule / code: `20261023120450_platform_audit_session_actor.sql`

## AUD-002

[Notion case](https://app.notion.com/p/404ead9eb8a881f19a92c7c3d1a5bbf6)

**Audit log append-only** · P1 · security · Role: tenant_admin

- Preconditions: —
- Steps: Delete/update audit row
- Test data: —
- Expected: "audit.audit_log is append-only"
- Rule / code: `20261006090400_audit_log.sql`

## AUD-003

[Notion case](https://app.notion.com/p/404ead9eb8a8813b9220c0350224f7fa)

**Hours override audited** · P2 · data-integrity · Role: tenant_admin

- Preconditions: APT-012
- Steps: Check audit
- Test data: —
- Expected: Reason stored
- Rule / code: `hours_override_reason.sql`
