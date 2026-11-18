# Weekly functional suite (API-level, live)

Runs against the hosted edge API with **qa.*** Demo Hospital logins only (never `demo.admin`).

```bash
# secrets expected under /home/box/.secrets (qa-tokens.json or medicore-qa-* passwords)
node scripts/qa/weekly/run.mjs
# or from the box checkout:
node /workspace/qa/weekly/run.mjs
```

## P0 cases added / enabled

- SIG-001 / SIG-002 — public hospital signup + duplicate email
- WIZ-001 — approve tagged signup, claim invite, complete setup wizard
- BRN-001 — tagged branch + valid GSTIN
- STF-001 / STF-004 — invite staff; last-admin protection on new tenant
- PAY-007 — cash daily limit ₹2,00,000 (s.269ST)
- E2E-001 / 002 / 003 / 005 — morning opening, busy OPD, refund dispute, CA GST

Created entities are logged as `entities-<runId>.json` beside the runner (box: `/workspace/qa/weekly/`).

## Synthetic auth for WIZ-001

Public Supabase signup sends email / rate-limits, and `@example.test` is rejected by Auth.
Each weekly run now seeds its own confirmed user via
`POST /api/v1/platform/qa/wizard-auth-users` (platform-admin JWT from
`/home/box/.secrets/medicore-master-login`; no outbound mail) and stores
credentials in `/home/box/.secrets/zz-qa-wiz-<runId>` as `email=` / `password=`
lines (never commit, never log). The email is
`zz-qa.wiz.<12-digit IST run id>@synthetic.example`. The SQL function
`identity.seed_zz_qa_wizard_auth_user` allows only those tagged addresses
(or `zz-qa-wiz-<digits>@synthetic.example`), re-checks
`identity.is_platform_admin()`, and never returns the password.

Hospital signup contact emails may use `@example.test` (accepted by the public API).
Invite emails use `@synthetic.example`.
