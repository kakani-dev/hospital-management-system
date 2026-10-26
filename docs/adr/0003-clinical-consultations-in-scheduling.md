# ADR 0003: Consultations and prescriptions live in a `clinical` schema owned by the scheduling service

Status: accepted (v1), 2026-10-26

## Context
Doctors need to record a consultation (chief complaint, notes, diagnosis, follow-up, advice) and a
prescription for a checked-in patient. The target design has a separate Clinical service, but none exists
yet. The scheduling service already owns the queue, check-in and the practitioner records that the
consultation hangs off. A new container app would add hosting cost and a new cross-service read of the queue.

## Decision
- A new Postgres schema, `clinical`, holds `consultations` and `prescription_lines`. Its tables and
  functions are owned by the scheduling service (`hms_svc_scheduling`). Migrations use the `scheduling_` prefix.
- The API is `/api/v1/consultations`. It is mapped by the Appointments module, and the edge routes
  `/api/v1/consultations/**` to scheduling.
- The schema boundary is kept strict so that it can be lifted out into a Clinical service later:
  - Other services never read `clinical.*`.
  - Clinical code reads other schemas only through ids or published `_v1` functions, plus the
    patient's soft-delete flag.
  - Finalize publishes `consultation.finalized` through the transactional outbox. The payload holds
    identifiers only.
- Permissions:
  - `clinical.write` is held by `doctor` only. A doctor also needs to be the practitioner on the visit.
  - `clinical.view` is held by doctor, nurse and tenant_admin.
  - Reception, billing, accountant, pharmacy, lab and viewer get no access, so billing never sees notes.
- Lifecycle:
  - A consultation is a draft until it is finalized. After that, triggers block every update and delete.
  - A correction is a new version (`root_id`, `version`, `supersedes_id`).
  - `row_version` gives optimistic concurrency.
  - Start, finalize and revise are idempotent, so a double submit is safe.
- Times are stored as UTC `timestamptz`. The print payload carries the branch time zone so the UI can display local times.

## Consequences
- Extracting the Clinical service later is a schema move plus an edge route change. No other service
  depends on the tables.
- Vitals are out of scope for v1, because there is no existing vitals support. The inventory medicine
  lookup is also out of scope: doctors lack `inventory.view`, and it would cross a service boundary.
  `prescription_lines.inventory_item_id` is a nullable soft link that is reserved for that work.
