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
Seed a confirmed user with SQL (no outbound mail), then store credentials in
`/home/box/.secrets/zz-qa-wiz-<id>` as `email=` / `password=` lines (never commit):

```sql
-- via Supabase SQL / MCP as postgres; use a unique zz-qa email each run
insert into auth.users (... email ..., encrypted_password := extensions.crypt(...), email_confirmed_at := now(), ...);
insert into auth.identities (...);
```

Hospital signup contact emails may use `@example.test` (accepted by the public API).
Invite emails use `@synthetic.example`.
