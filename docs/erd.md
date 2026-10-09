# Entity relationship diagram (Sprint 0–2)

Source of truth: `supabase/migrations/`. `auth.users` is provided by Supabase Auth.

```mermaid
erDiagram
  AUTH_USERS ||--|| USER_PROFILES : "1:1"
  AUTH_USERS ||--o{ MEMBERSHIPS : "has"
  TENANTS ||--o{ BRANCHES : "owns"
  TENANTS ||--o{ MEMBERSHIPS : "grants"
  BRANCHES |o--o{ MEMBERSHIPS : "scopes (null = all branches)"
  TENANTS ||--o{ PATIENTS : "owns"
  BRANCHES ||--o{ PATIENTS : "registered at"
  TENANTS ||--o{ AUDIT_LOG : "scopes"
  TENANTS ||--o{ PRACTITIONERS : "owns"
  AUTH_USERS |o--o{ PRACTITIONERS : "optional staff link"
  PRACTITIONERS ||--o{ SCHEDULES : "works"
  BRANCHES ||--o{ SCHEDULES : "at"
  PRACTITIONERS ||--o{ APPOINTMENTS : "sees"
  PATIENTS ||--o{ APPOINTMENTS : "books"
  BRANCHES ||--o{ APPOINTMENTS : "at"
  BRANCHES ||--o{ QUEUE_ENTRIES : "OPD queue"
  PATIENTS ||--o{ QUEUE_ENTRIES : "checked in"
  APPOINTMENTS |o--o| QUEUE_ENTRIES : "checked in once"
  PRACTITIONERS |o--o{ QUEUE_ENTRIES : "assigned (null = walk-in)"
  BRANCHES ||--o{ QUEUE_COUNTERS : "token counter per day"
  TENANTS ||--o{ OUTBOX : "scopes"

  AUTH_USERS {
    uuid id PK
    text email
  }
  TENANTS {
    uuid id PK "tenant id"
    text code UK
    text name
    text status "active|suspended|archived"
    jsonb settings
    timestamptz created_at
    uuid created_by
    timestamptz updated_at
    uuid updated_by
  }
  BRANCHES {
    uuid id PK
    uuid tenant_id FK
    text code "UK(tenant_id, code)"
    text name
    text timezone
    bool is_active
  }
  USER_PROFILES {
    uuid id PK "= auth.users.id"
    text email
    text display_name
  }
  MEMBERSHIPS {
    uuid id PK
    uuid tenant_id FK
    uuid user_id FK
    uuid branch_id "FK(tenant_id, branch_id)"
    text role
    text status "active|invited|suspended"
  }
  PATIENTS {
    uuid id PK
    uuid tenant_id FK
    uuid registered_branch_id "FK(tenant_id, registered_branch_id)"
    text mrn "UK(tenant_id, mrn)"
    text first_name
    text last_name
    date date_of_birth
    text sex
    text phone
    text email
    timestamptz deleted_at "soft delete (RPC only)"
    uuid deleted_by "Sprint 2, RPC only"
    text deletion_reason "Sprint 2, <=500"
  }
  PRACTITIONERS {
    uuid id PK
    uuid tenant_id FK
    uuid user_id "UK(tenant_id, user_id), nullable"
    text display_name "1..120"
    text specialty
    bool is_active
  }
  SCHEDULES {
    uuid id PK
    uuid tenant_id FK
    uuid practitioner_id "FK(tenant_id, practitioner_id)"
    uuid branch_id "FK(tenant_id, branch_id)"
    smallint weekday "ISO 1=Mon..7=Sun"
    time start_time "branch-local"
    time end_time "branch-local, > start_time"
    smallint slot_minutes "5..240, default 15"
    date valid_from
    date valid_to
    bool is_active
  }
  APPOINTMENTS {
    uuid id PK
    uuid tenant_id FK
    uuid branch_id "FK(tenant_id, branch_id)"
    uuid practitioner_id "FK(tenant_id, practitioner_id)"
    uuid patient_id "FK(tenant_id, patient_id)"
    timestamptz starts_at
    timestamptz ends_at "<= 8h after starts_at"
    tstzrange during "generated [starts_at, ends_at)"
    text status "booked|checked_in|in_consultation|completed|cancelled|no_show"
    text reason "PHI, <=500"
    text cancel_reason
    timestamptz checked_in_at
    timestamptz started_at
    timestamptz completed_at
    timestamptz cancelled_at
  }
  QUEUE_ENTRIES {
    uuid id PK
    uuid tenant_id FK
    uuid branch_id "FK(tenant_id, branch_id)"
    date queue_date "branch-local"
    int token_no "UK(tenant_id, branch_id, queue_date, token_no)"
    uuid patient_id "FK(tenant_id, patient_id)"
    uuid appointment_id "UK, nullable"
    uuid practitioner_id "nullable = walk-in"
    text status "waiting|in_consultation|done|cancelled"
    timestamptz checked_in_at
    timestamptz called_at
    timestamptz completed_at
    timestamptz cancelled_at
  }
  QUEUE_COUNTERS {
    uuid tenant_id PK
    uuid branch_id PK
    date queue_date PK
    int last_token
  }
  OUTBOX {
    bigint id PK "identity"
    uuid event_id UK
    uuid tenant_id
    text aggregate_type "appointment|queue_entry"
    uuid aggregate_id
    text event_type
    jsonb payload "no PHI"
    timestamptz occurred_at
    text status "pending|processing|done|dead"
    int attempts
    timestamptz available_at
    text claimed_by
    timestamptz claimed_until
    timestamptz processed_at
    text last_error
  }
  AUDIT_LOG {
    bigint id PK
    uuid tenant_id
    text schema_name
    text table_name
    uuid record_id
    text action "INSERT|UPDATE|DELETE"
    jsonb old_data
    jsonb new_data
    uuid changed_by
    timestamptz changed_at
  }
```

All tables except `audit_log`, `queue_counters` and `outbox` also carry `created_at, created_by, updated_at, updated_by` (DB-managed; never sent by the API).

## Schemas

| Schema | Service | Tables |
|---|---|---|
| `identity` | Identity & Tenant | tenants, branches, user_profiles, memberships |
| `patient` | Patient | patients |
| `appointment` | Appointments & OPD queue (Sprint 2) | practitioners, schedules, appointments, queue_entries, queue_counters |
| `messaging` | Transactional outbox (Sprint 2) | outbox |
| `audit` | Audit | audit_log |

## Sprint 2 constraints and rules

Source: `/workspace/SPRINT2-CONTRACT.md` (DB v1) and migrations `20261010090000`–`20261010090300`.

- **Tenancy.** Every new table has `tenant_id`; child rows reference parents through composite FKs `(tenant_id, x_id)`, so no row can point at another tenant's row. RLS is on for every table.
- **Patients (2.1).** Soft delete and restore only through `patient.soft_delete_patient(id, reason)` (tenant_admin, receptionist) and `patient.restore_patient(id)` (tenant_admin); `authenticated` has no `update (deleted_at)` grant. Deleted rows are visible to tenant_admin only and can't be edited until restored. The MRN stays reserved after delete. Deleting a patient with open appointments or queue entries fails (`55000`). Indexes: normalized phone (`patient.normalize_phone`, last 10 digits), DOB, and lower(name)+DOB, all `where deleted_at is null`.
- **Duplicate detection.** `patient.find_duplicate_patients(...)` (SECURITY INVOKER) returns up to 20 same-tenant, non-deleted matches by name+DOB or normalized phone, with `match_reasons`. Advisory only; the DB never blocks a duplicate.
- **Schedules.** Weekly, branch-local wall-clock time, no overnight shifts; overlapping active rows for one practitioner are excluded (`23P01`). Slots are computed by `appointment.available_slots(...)`, never stored (max 31-day range).
- **Appointments.** No overlap per practitioner: `exclude using gist (tenant_id =, practitioner_id =, during &&)` for status `booked|checked_in|in_consultation|completed` (`23P01`; cancelled and no_show free the time). Patient-side overlap is not enforced. New rows must be `booked`; transitions are enforced by a trigger (`23514 invalid_transition:...`); time, practitioner, patient and branch are immutable once not `booked`. No DELETE (cancel instead).
- **OPD queue.** Written only by `appointment.check_in(...)` and `appointment.set_queue_status(...)`. Tokens are per (tenant, branch, branch-local date) from 1, allocated atomically through `queue_counters` (no client grants); an appointment is checked in at most once and only on its branch-local day. Queue reads are branch-scoped.
- **Outbox.** Written only by AFTER triggers on appointments and queue entries (same transaction), payload has no PHI; consumed by the `hms_dispatcher` role through `claim_outbox` / `complete_outbox` / `fail_outbox` with SKIP LOCKED leases. Delivery is at-least-once; dedupe on `event_id`.
- **Deferred.** Branch-role binding (`has_branch_role`) is still enforced in the API only; see `docs/backlog/pr1-db-hardening-draft.sql`.
