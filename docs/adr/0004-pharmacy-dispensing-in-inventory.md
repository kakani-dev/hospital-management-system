# ADR 0004: Pharmacy dispensing lives in a `pharmacy` schema hosted by the inventory service

Status: accepted (v1), 2026-10-27

## Context
Issue #106 needs pharmacists to see finalized prescriptions, dispense them against batch stock (FEFO,
partial dispensing), and later sell OTC and bill with GST. The Notion spec plans a separate pharmacy
service (`hms_svc_pharmacy`) calling inventory `_v1` contracts. No such service exists, and a new
container app would add hosting cost (free tier only) and new edge, deploy and secret wiring.
Stock moves must be atomic with the dispense record, which is simplest in the service that owns the ledger.

## Decision
- A new schema, `pharmacy`, holds `dispense` and `dispense_line`. Its functions are executed by the
  inventory service (`hms_svc_inventory`). Migrations use the `inventory_` prefix.
- The API is under the existing edge route `/api/v1/inventory/**`:
  `GET /pharmacy/queue`, `GET /pharmacy/prescriptions/{id}`, `POST /pharmacy/dispenses` (Idempotency-Key).
  No edge, deploy or new-service change.
- Reading prescriptions: an exception to ADR 0003's "other services never read `clinical.*`". The
  pharmacy reads finalized consultations, their lines, the doctor's display name and the patient's
  name and MRN **only inside security-definer functions** that return a fixed projection. The inventory
  login has no table grants on `clinical.*` or `patient.*` (SQL test 39 still holds). Drafts and notes
  other than the diagnosis line are never exposed. When a Clinical service exists this becomes a `_v1` read contract.
- Stock: each dispensed batch is one `inventory.stock_ledger` row, movement `dispense`, source
  `pharmacy_dispense` / dispense-line id, at the batch's last purchase cost. The ledger trigger still
  refuses negative stock; the dispense function locks the balance rows first, so two pharmacists
  cannot oversell. Expired batches are never picked. FEFO order is expiry date, then batch creation.
- Permissions: `pharmacy.view` and `pharmacy.dispense`, held by `pharmacist` and `tenant_admin`.
  Branch scope uses `identity.can_access_branch`. The tenant comes from the server context only.
- Prescriptions carry no quantity, so the pharmacist enters the quantity per line and marks a line
  finished; status is `pending` (nothing given), `partial` or `dispensed` (every line finished).
  A finished line cannot be dispensed again. Superseded prescription versions are not dispensable.
- Dispense rows are append-only and audited.

## Consequences
- Lifting pharmacy into its own service later means moving the schema and replacing the clinical
  reads with a published contract; the API paths would move from `/inventory/pharmacy/*` to `/pharmacy/*`.
- GST billing of dispenses (PR3) goes through billing's own contract, not direct writes.
