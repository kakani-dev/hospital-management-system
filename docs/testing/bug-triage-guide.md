# Bug triage guide

## 1. Pin the context
- Role (from the menu/profile), branch selected, tenant (MediCore Demo Hospital unless told otherwise).
- Retry with a second role and a second branch: if only one role fails, suspect permissions (`apps/web/src/lib/permissions.ts`, `identity.role_permissions`).
- Note time in IST; anything near midnight may be a time-zone bug (branch zone overrides hospital zone).

## 2. Browser evidence
Open DevTools: Console (red errors) and Network (filter Fetch/XHR, find the failing request).

| Status | Meaning in MediCore |
|---|---|
| 401 | Not signed in or session expired. Log in again; if it repeats, auth bug. |
| 403 | Your role/branch is not allowed (`Forbidden`, "Your role does not permit this action" or SQL 42501). Check the role matrix before filing. |
| 404 | Record does not exist **for your tenant** (RLS hides other tenants' data, so cross-tenant IDs return 404, not 403). |
| 409 | Conflict: duplicate (unique key, e.g. ABHA, email_registered, possible_duplicate), double-submit, or state already changed (already checked in). |
| 422 | Privacy module validation (unprocessable request). Other modules return 400 for validation. |
| 400 | Validation/business rule; the `detail` text is the SQL rule message — quote it exactly. |
| 429 | Rate limited: 300 req/min per user, warm-up 10/min per IP, hospital-registration limits. Wait 1 minute. |
| 5xx | Server error; always a bug. Capture the request ID. |

## 3. Request ID
Copy the `X-Request-Id` response header (and `traceparent` if present). Developers use it to find the server log line.

## 4. UI, API or data?
- **UI**: the request returned correct data (Preview tab) but the screen shows it wrong, or no request was sent.
- **API**: the request returned an error or wrong JSON for correct input.
- **Data**: the API faithfully returns wrong stored values (e.g. bill made before GSTIN was set); compare with another record created fresh.

## 5. Minimal repro
Strip steps until removing any one makes the bug disappear. Use fresh synthetic data in the demo tenant. Never paste real patient data or passwords.

## 6. File it
File at https://github.com/kakani-dev/hospital-management-system/issues/new/choose using **Bug report** (or **Test failure** for a failed case ID). Labels: `bug`, one of `severity:high|medium|low`, and `qa`. Check the Known issues list first.

Template fields: test case ID, role, tenant/branch, environment+time (IST), steps, expected, actual, console + network evidence (status, request ID), severity.

## Known issues (do not re-file)
- #90 CA exports all download as `earnings.csv`.
- #91 warm-up call errors in browser console on most pages.
- #92 GST summary shows UNREGISTERED for branch with GSTIN (likely bills before GSTIN was added).
- #63 UPI QR uses a placeholder UPI ID (bank/UPI mapping not built).
- No screen to close a cashier counter or enter counted cash.
- No prescriptions/consultation notes screen for doctors; no lab screens.
- Draft bills show "Draft draft" with no bill number.
- "Data requests" sits under the Pharmacy menu for reception.
- Pharmacists can view but not manage stock.
- First load after idle ~13.5 s (cold start); bills page 5–7 s.
