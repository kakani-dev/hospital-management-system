# Entity relationship diagram (Sprint 0)

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
    timestamptz deleted_at "soft delete"
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

All tables except `audit_log` also carry `created_at, created_by, updated_at, updated_by`.

## Schemas

| Schema | Service | Tables |
|---|---|---|
| `identity` | Identity & Tenant | tenants, branches, user_profiles, memberships |
| `patient` | Patient | patients |
| `audit` | Audit | audit_log |
