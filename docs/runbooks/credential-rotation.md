# Zero-downtime credential rotation (issue #68)

Tool: `scripts/ops/credential_rotation.py` (tests: `credential_rotation_test.py`, run in CI).
It never prints a password, key or connection string, only role names, slots and 12-char
sha256 prefixes. Working files go to `ROTATION_DIR` (default `/dev/shm/hms-rotation`, mode 0700/0600).
Env: `RG` (resource group, required), `ROTATION_APP_PREFIX` (default `ca-hms-`).
Needs `az` (logged in, read secrets) and `gh` (repo secret write).

## Why this design

On 2026-10-31 a single-login rotation broke production: the failed deploy restored the old
app secret, but the database role already had the new password. Rule now: **the database
never stops accepting the credential the app is currently using until the app has moved off
it and been verified.** Any rollback is then just "restore the previous app secret", which
the deploy already does on failure.

## Preconditions (every rotation)

1. `ACA_SECRETS_SOURCE=github` (in `legacy` the deploy does not write `hms-db`/`hms-edge-key`).
2. No `deploy-aca` run in flight, and none from other workstreams until you finish. One rotation at a time.
3. Production healthy: `/health/ready` 200 on all apps, QA smoke passes.
4. Note the hash prefixes of live secrets (`credential_rotation.py status <svc>`) for the evidence log.

## Database logins: blue/green slots

Each service has two logins: slot a `hms_<svc>_login` and slot b `hms_<svc>_login_b`. Both are
NOINHERIT members of `hms_svc_<svc>`; the app runs `SET ROLE hms_svc_<svc>`
(`Database:SessionRole`), so privileges come from the group and either slot works. Slot b is
created on the first rotation as a copy of slot a (connection limit and per-role settings
such as `statement_timeout` are copied from `pg_roles`, not hard-coded).

Per service, in rollout order (identity, patients, scheduling, billing, inventory, privacy):

| Step | Command | Live effect |
|---|---|---|
| 1 | `credential_rotation.py prepare <svc>` | none; writes new connstr + `<svc>.prepare.sql` (SCRAM verifier only) |
| 2 | run `<svc>.prepare.sql` (Supabase SQL editor or MCP `execute_sql`) | standby login exists/enabled with new password; app untouched |
| 3 | `credential_rotation.py publish <svc>` | GitHub secret `HMS_DB_<SVC>` updated; apps untouched |
| 4 | dispatch `deploy-aca` with the current tag, blank service | app secret written, revision restarted on the standby slot |
| 5 | verify: run succeeded, `/health/ready` 200, smoke passes, `status <svc>` shows the new slot | |
| 6 | `credential_rotation.py retire <svc>`, run `<svc>.retire.sql` | old slot `NOLOGIN PASSWORD NULL`. Refuses while the app still uses it |
| 7 | `credential_rotation.py cleanup` | shreds working files |

Several services can share one deploy: do steps 1-3 for each, one deploy, then step 5-6 for each.
Wait a few minutes before step 6 so old replicas drain (pooled sessions of the old role end when
replicas stop; `NOLOGIN` only blocks new ones).

### Rollback

- Before step 4: nothing live changed. Re-run `gh secret set HMS_DB_<SVC>` with the old value
  (`az containerapp secret show ... | gh secret set HMS_DB_<SVC>`, piped, never echoed) or just prepare again later.
- Step 4 fails: the deploy restores the old app secret itself; the old slot still works, so the
  app stays up. Also restore the GitHub secret as above, so the next deploy does not retry.
- After step 6 and a problem appears: the old slot is disabled; rotate again (it moves to the
  other slot with a fresh password). Do not re-enable an old password.

## Edge key: dual key

Services accept `Edge:Key` and, when set, `Edge:PreviousKey` (`EdgeKeyMiddleware`). The edge
sends `Edge:Key`. The edge rolls last, so every service accepts the new key before it is sent.

1. `credential_rotation.py edge-prepare`: `HMS_EDGE_KEY_PREVIOUS` = live key, `HMS_EDGE_KEY` = new random key.
2. Dispatch `deploy-aca` with the current tag and a blank service (all seven roll; the guard refuses partial rolls).
3. Verify `/health/ready`, a 401 without a key on a service URL, smoke through the edge.
4. `credential_rotation.py edge-retire`: `HMS_EDGE_KEY_PREVIOUS` = current key (equal keys = single key).
5. Dispatch a full deploy again; the old key is no longer accepted.

Rollback: if step 2 fails the deploy restores the old values on the apps; then set
`HMS_EDGE_KEY` back to the old key from `HMS_EDGE_KEY_PREVIOUS`'s source (the live edge
secret, piped) before any other deploy.

`HMS_EDGE_KEY_PREVIOUS` is an `optional` manifest row: while unset nothing is written, so
merging this support changed nothing live.

## hms_api_login (medicore-hms-api)

Same blue/green pattern, by hand: `hms_api_login_b` as a copy of `hms_api_login` (member of
`hms_api`), set its verifier, update the api service's connection secret to slot b, redeploy and
verify, then `NOLOGIN PASSWORD NULL` on `hms_api_login`. The api service is outside
`aca-secrets.tsv`, so the tool's `prepare`/`publish` do not cover it; build the verifier with
`python3 -c 'import credential_rotation as c,getpass;print(c.scram_verifier(getpass.getpass()))'`
from `scripts/ops` (prints the verifier, not the password).

## Never

- Change a role's password in place while an app uses that role.
- Print or paste a secret; always pipe (`... | gh secret set NAME`).
- Run two deploys concurrently, or rotate while another workstream deploys.
