# MediCore HMS — Business-logic audit (2026-10-20, IST)

Scope: Level 1 (tenants, branches, staff/roles, patients, practitioners/schedules, appointments, queue).
Method: read migrations/SQL functions/triggers/RLS + .NET endpoints; verified with automated tests run locally
(fresh DB from all migrations): **SQL 898 assertions / 0 failures** (new file `supabase/tests/29_business_logic_audit_test.sql`, 31 assertions),
**unit 419/419**, **integration through the YARP edge + 3 services 268/268** (new `QaBookingWindowApiTests`), **DB tests 19/19**,
plus a 10-way parallel race insert on one slot (1 row survived).

Totals: **OK 41 · BUG 1 (fixed) · GAP 9** (gaps = product decisions or new features, not changed).

## A. Tenant creation / lifecycle (full depth)

| # | Rule | Where enforced | Test | Status | Sev |
|---|---|---|---|---|---|
| A1 | Only platform admin can create (direct) | `platform_create_tenant` → `require_platform_admin`; `create_tenant` 42501 for clients | 29 (2 asserts), 24 | OK | – |
| A2 | Only platform admin can approve/reject | `platform_approve_signup/_reject_signup` | 24 | OK | – |
| A3 | No double approve / idempotent | `FOR UPDATE` + status='pending' → 55000 | 29 "cannot be approved twice", 24 | OK | – |
| A4 | Double submit of Create hospital | `tenants_code_key` unique → 23505, one tenant only | 29 | OK | – |
| A5 | Public sign-up: one pending per email, rate limit 3/24h/source | unique index + function | 24 | OK | – |
| A6 | Code lowercase format | `tenants_code_format` check (`^[a-z0-9][a-z0-9-]{1,39}$`) | 29 | OK (input is not auto-lowercased; mixed case is rejected, UI lowercases) | Low |
| A7 | Code immutable | no UPDATE grant on `identity.tenants` for clients; no rename function | 29 | OK | – |
| A8 | Time zone required + valid IANA | `create_tenant` / `submit_tenant_signup` 22023 | 29, 24, 19 | OK | – |
| A9 | Default branch created consistently | `create_tenant` (shared by both paths) → one `main`/"Main" branch, no override | 29 (direct + approve) | OK — both paths identical (manual wording was unclear, behaviour is consistent) | – |
| A10 | default_country_code derived from zone | `default_tenant_country_code` | 29 (+91 Kolkata, +1 New York) | OK | – |
| A11 | MRN counter initialised | lazily upserted on first patient (`assign_mrn`) | 29 first patient gets MRN | OK | – |
| A12 | First-admin invite created, single use, email match, expiry | `issue_invite_link`, `claim_invite_link` (pending+expires_on, email check) | 29, 24 | OK | – |
| A13 | Audit fields | `audit.stamp_audit_columns` | 29, 05 | OK | – |
| A14 | Outbox event on tenant create/approve/suspend | outbox aggregate types limited to appointment/queue_entry; `tenant_status_changes` table is the history | – | GAP (no consumer exists yet; add `tenant.*` events when notifications service lands) | Low |
| A15 | New tenant fully isolated | RLS `current_tenant_ids()` | 29 (Alpha admin sees none), 02 | OK | – |
| A16 | New admin can immediately do branch→practitioner→schedule→patient→booking | | 29 full journey | OK | – |
| A17 | Suspend/reactivate; suspended users blocked | `platform_set_tenant_status` (+reason, history); `current_tenant_ids` requires `t.status='active'`; invites can't be claimed | 29, 24 | OK | – |

## B. Invites / memberships
| B1 | One-time links | `claim_invite_link` status pending | 29, 24 | OK | – |
| B2 | Expiry | `expires_on > now()` | 24 | OK | – |
| B3 | Email must match | 42501 invite_email_mismatch | 29 | OK | – |
| B4 | Branch-scoped memberships | `memberships_tenant_user_branch_key`, `can_access_branch` | 09, 03 | OK | – |
| B5 | Last-admin protection | admins cannot remove their own membership; only admins remove members | probe | OK (indirect). No explicit "last admin" guard if an admin demotes/suspends the other last admin — GAP | Low |

## C. Branches
| C1 | Unique code per tenant (live rows) | partial unique index | 29, 04 | OK | – |
| C2 | Time-zone override; days in branch zone | `branch_time_zone_v1`, `branch_local_date_v1` | 19 | OK | – |
| C3 | No delete with future appointments/queue | `branch_has_open_activity_v1` in `soft_delete_branch` | existing integration | OK | – |
| C4 | Soft delete | `is_deleted` + restore | 14/20 | OK | – |
| C5 | Unique branch *name* per tenant | only code is unique | – | GAP (decision: also unique names?) | Low |

## D. RBAC (ADR 0001 vs enforcement)
| D1 | Matrix in DB (`has_tenant_permission`) and API (`HmsPermissions`, `CanAtBranch`) | 28, InProcessApiTests | OK | – |
| D2 | Platform admin gets no patient data | 28 | OK | – |
| D3 | Who may book (doctor/nurse can't) | ADR | – | DECISION for Mohith | – |

## E. Patients
| E1 | Auto MRN, unique per tenant, immutable | `assign_mrn`, `guard_mrn`, `patients_tenant_mrn_key` | 25, 27 | OK | – |
| E2 | Phones E.164, one primary, one WhatsApp, no duplicate numbers, "same as phone" = one row with both flags | `patient_phones` indexes, `set_patient_phones` | 26 | OK | – |
| E3 | Duplicate detection | `find_duplicate_patients` + API check | 10, QaDuplicateDetection | OK | – |
| E4 | Soft delete hides, keeps MRN reserved; blocked while open visits | `soft_delete_patient`, unique MRN unchanged | 10, QaPatientEditDelete | OK | – |
| E5 | Tenant isolation | RLS | 02, 29 | OK | – |

## F. Practitioners / schedules
| F1 | No overlapping schedules per practitioner (any branch) | `schedules_no_overlap` gist exclusion | 29, 11 | OK | – |
| F2 | valid_from ≤ valid_to; start<end; slot 5–240 min | check constraints | 29, 11 | OK | – |
| F3 | Breaks inside a day | modelled as two schedules per weekday | – | OK (no separate break entity) / GAP for explicit breaks | Low |
| F4 | Can't delete practitioner with open appointments | `soft_delete_practitioner` | AuditSoftDelete | OK | – |

## G. Appointments
| G1 | No double booking, concurrency safe | `appointments_no_practitioner_overlap` exclusion + API pre-check; 40P01→409 | 29, QaDoubleBooking (parallel), 10-way psql race | OK | – |
| G2 | **No booking in the past** | was **not enforced anywhere** (API accepted any date) | 29, new `QaBookingWindowApiTests` | **BUG → FIXED** (`appointment.assert_bookable_window`, called on book + reschedule; earlier branch-local *day* → 400; same-day allowed, as in Bahmni) | High |
| G3 | Booking only within the practitioner's schedule | not enforced (UI offers only free slots; API accepts any time) | – | GAP / DECISION (Bahmni allows outside-hours with a warning) | Med |
| G4 | Status machine booked→checked_in→in_consultation→completed; cancel; no-show only after start | `enforce_appointment_transition` | 29, 11, QaDoubleBooking | OK | – |
| G5 | Reschedule frees old slot | same row moves; exclusion excludes self | S2Appointment | OK | – |
| G6 | Cancel/no-show free the slot; completed blocks | exclusion predicate on status | QaDoubleBooking | OK | – |
| G7 | Follow-up links to parent appointment | UI pre-fills patient/doctor only; no `parent_appointment_id` | – | GAP (schema change → proposal) | Med |
| G8 | Outbox events on appointment changes | `emit_appointment_event` | 29, 13 | OK | – |

## H. Queue / day logic / audit
| H1 | Token per branch per local day, resets at local midnight | `queue_counters(tenant,branch,queue_date)` + `branch_local_date_v1` | 12, QaQueueTokenOrder | OK | – |
| H2 | One active entry per patient per day | unique index | 12 | OK | – |
| H3 | End-of-day close of leftover entries | none | – | GAP (decision: auto mark no-show/closed at local midnight?) | Low |
| H4 | UTC storage, local-day evaluation | timestamptz everywhere + branch zone helpers | 19 | OK | – |
| H5 | Audit columns + is_deleted on every table; audit log | `stamp_audit_columns`, `log_row_change`, guardrail tests | 05, 14 | OK | – |

## Benchmark vs established HMS (public docs)

| Item | Bahmni/OpenMRS | Practo Ray / eHospital / Epic-Cerner basics | MediCore | Verdict |
|---|---|---|---|---|
| Duplicate patient detection | yes | standard | name+DOB+phone check on register | Meets |
| ABHA / national ID readiness | — | ABDM M1 requires one ABHA ↔ one patient ID, validated before creating a patient [3][4] | no field | **Missing** (proposal) |
| Age from DOB | shown | standard | DOB stored, age not displayed | Partial (UI-only; not changed now to avoid clashing with the booking-quick-register work) |
| Walk-in vs scheduled | walk-in flag on appointment [1] | standard | walk-in check-in creates a queue entry without appointment | Meets |
| Booking date rules | "only current and future dates are allowed" [1] | standard | **fixed in this PR** | Meets (after fix) |
| Overbooking / outside hours | allowed with warning [1][2] | configurable | double booking hard-blocked; outside-hours not checked | Partial → decision |
| Slot buffers | — | Practo/Epic: buffer/padding between slots | none | Missing (proposal) |
| Cancellation reasons | yes | standard | free-text reason (≤500) | Meets (coded reason list = proposal) |
| No-show tracking | "missed" status [1] | standard | no_show after start time | Meets |
| Token display | — | eHospital/ABDM scan-and-register returns token numbers [5] | queue board with tokens | Meets |
| Audit trail | yes | standard | row-level audit log + audit columns | Meets |
| Clicks to register + book | — | — | quick-register inside booking (other worker, in progress) | Partial → being addressed |

Sources: [1] Bahmni — Creating and Managing Appointments, https://bahmni.atlassian.net/wiki/spaces/BAH/pages/138182707 ;
[2] Bahmni — Configure Views of Appointments, https://bahmni.atlassian.net/wiki/spaces/BAH/pages/137953307 ;
[3] ABDM M1 test cases (TAGGING_UNIQUEPATIENTID_UNIQUEABHANUMBER), https://docs.abdm.gov.in/docs/hiecm/v3/resources/test-cases/m1 ;
[4] ABDM M1 Identity, https://docs.abdm.gov.in/docs/hiecm/v3/api/m1/ ;
[5] ABDM Scan and Register, https://docs.abdm.gov.in/docs/hiecm/v3/use-cases/scan-and-register .
Practo Ray / Epic / Cerner rows are general practice; their docs are not public, so no citation is claimed.
