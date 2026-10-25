# Cross-tenant isolation test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## XT-001

[Notion case](https://app.notion.com/p/404ead9eb8a881aaa6b0d2c23db05cd9)

**Tenant B's patient ID used by tenant A** · P0 · security · Role: receptionist

- Preconditions: IDs from two tenants
- Steps: GET tenant B patient id as tenant A
- Test data: —
- Expected: 404 (RLS hides), never data
- Rule / code: `RLS current_tenant_ids(); HmsProblems NotFound`

## XT-002

[Notion case](https://app.notion.com/p/404ead9eb8a8810d9c11fd50575b4de9)

**Client-sent tenant_id ignored** · P0 · security · Role: receptionist

- Preconditions: —
- Steps: POST patient with tenant_id of B
- Test data: —
- Expected: Created in A or rejected; never in B
- Rule / code: `RLS with check identity.current_tenant_ids`

## XT-003

[Notion case](https://app.notion.com/p/404ead9eb8a8814d8f02fa9df5ae9cae)

**Tenant B's bill/appointment IDs** · P0 · security · Role: billing

- Preconditions: —
- Steps: Pay/refund B's bill
- Test data: —
- Expected: 404 "bill not found"
- Rule / code: `billing RLS`

## XT-004

[Notion case](https://app.notion.com/p/404ead9eb8a8817fbf5fc08a21776054)

**Branch does not belong to tenant** · P1 · security · Role: tenant_admin

- Preconditions: —
- Steps: Use B's branch id
- Test data: —
- Expected: "branch does not belong to tenant"
- Rule / code: `identity migrations`

## XT-005

[Notion case](https://app.notion.com/p/404ead9eb8a881bd861ac26f11c762a1)

**Branch out of scope for member** · P1 · security · Role: billing

- Preconditions: Member of branch 1
- Steps: Bill at branch 2
- Test data: —
- Expected: "branch out of scope"/"not permitted for this branch"
- Rule / code: `billing_commands.sql`

## XT-006

[Notion case](https://app.notion.com/p/404ead9eb8a88173964ac107debe1b68)

**Unauthenticated API** · P0 · security · Role: anonymous

- Preconditions: —
- Steps: Call /api without token
- Test data: —
- Expected: 401
- Rule / code: `EdgeHost auth`
