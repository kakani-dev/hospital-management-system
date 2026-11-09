# Weekly functional suite (API-level, live)

Runs against the hosted edge API with **qa.*** Demo Hospital logins only (never `demo.admin`).

```bash
# from a workstation with secrets in /home/box/.secrets (or set HMS_EDGE_URL)
node scripts/qa/weekly/run.mjs
```

## P0 cases added / enabled

- SIG-001 / SIG-002 — public hospital signup + duplicate email
- WIZ-001 — approve tagged signup, claim invite, complete setup wizard
- BRN-001 — tagged branch + valid GSTIN
- STF-001 / STF-004 — invite staff; last-admin protection on new tenant
- PAY-007 — cash daily limit ₹2,00,000 (s.269ST)
- E2E-001 / 002 / 003 / 005 — morning opening, busy OPD, refund dispute, CA GST

Created entities are logged under `scripts/qa/weekly/entities-<runId>.json` (and `/workspace/qa/weekly/` when run from the box checkout).

Synthetic emails use `@example.test` / `@synthetic.example`. Wizard auth users are seeded via Supabase SQL (no outbound mail); see `createSyntheticAuthUser` in `lib.mjs`.
