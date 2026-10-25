# Inventory test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## INV-001

[Notion case](https://app.notion.com/p/404ead9eb8a88111841dc395a1cf1aa4)

**Pharmacist views stock** · P1 · happy · Role: pharmacist

- Preconditions: —
- Steps: Open /stock
- Test data: —
- Expected: Visible; edit controls hidden
- Rule / code: `permissions.ts pharmacist inventory.view`

## INV-002

[Notion case](https://app.notion.com/p/404ead9eb8a881b4bc16c2934b093fd5)

**Add drug item** · P1 · happy · Role: tenant_admin

- Preconditions: —
- Steps: Add drug with generic, brand, HSN 3004
- Test data: —
- Expected: Saved
- Rule / code: `20261023170000_inventory_foundation.sql`

## INV-003

[Notion case](https://app.notion.com/p/404ead9eb8a881de8881e9cbdbb5b442)

**Drug needs generic name** · P2 · negative · Role: tenant_admin

- Preconditions: —
- Steps: Drug without generic
- Test data: —
- Expected: "genericName is required for a drug"
- Rule / code: `inventory_foundation.sql`

## INV-004

[Notion case](https://app.notion.com/p/404ead9eb8a881d2a14ec6e2a3cdfcdf)

**HSN 4-8 digits** · P2 · boundary · Role: tenant_admin

- Preconditions: —
- Steps: HSN 123, 123456789
- Test data: —
- Expected: "hsnCode must be 4 to 8 digits"
- Rule / code: `inventory_foundation.sql`

## INV-005

[Notion case](https://app.notion.com/p/404ead9eb8a8815891c2c62df2b82036)

**Batch expiry after mfg** · P2 · negative · Role: tenant_admin

- Preconditions: —
- Steps: expiry < mfg
- Test data: —
- Expected: "expiryDate must be after mfgDate"
- Rule / code: `inventory_foundation.sql`

## INV-006

[Notion case](https://app.notion.com/p/404ead9eb8a881b3a62cf60fc931b742)

**Batches immutable** · P2 · data-integrity · Role: tenant_admin

- Preconditions: —
- Steps: Edit batch
- Test data: —
- Expected: "batches are immutable"
- Rule / code: `inventory_foundation.sql`

## INV-007

[Notion case](https://app.notion.com/p/404ead9eb8a8819f8beccbc4a4fb49d5)

**Pharmacy needs drug licence** · P2 · negative · Role: tenant_admin

- Preconditions: Pharmacy without licence
- Steps: Create
- Test data: —
- Expected: "a pharmacy needs a current drug licence"
- Rule / code: `inventory_foundation.sql`

## INV-008

[Notion case](https://app.notion.com/p/404ead9eb8a881509872fa00d6774204)

**Low stock flag** · P2 · happy · Role: tenant_admin

- Preconditions: reorderLevel 10
- Steps: Qty 9
- Test data: —
- Expected: Low stock flagged; negative reorder rejected
- Rule / code: `20261025220300_inventory_stock_low_flag.sql`

## INV-009

[Notion case](https://app.notion.com/p/404ead9eb8a881da9d60f8da9b4f4159)

**Import max 500 rows** · P3 · boundary · Role: tenant_admin

- Preconditions: —
- Steps: Import 501
- Test data: —
- Expected: "import at most 500 rows"
- Rule / code: `inventory_foundation.sql`

## INV-010

[Notion case](https://app.notion.com/p/404ead9eb8a8815c8c85c996747ad5ff)

**Pharmacist cannot manage stock** · P2 · edge · Role: pharmacist

- Preconditions: —
- Steps: Edit stock
- Test data: —
- Expected: Known gap: view-only
- Rule / code: `User manual gap`
