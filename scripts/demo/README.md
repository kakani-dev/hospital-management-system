# Demo data (synthetic)

> **Standing rule:** All dummy and demo data must be inserted into the tenant **'MediCore Demo Hospital'**
> (tenant id `77519cf6-1d9b-4954-8bc6-f29bbb734786`, admin login `demo.admin@demo.medicore.test`).
> Never create a new demo tenant.

These scripts target **only** tenant `77519cf6-1d9b-4954-8bc6-f29bbb734786` (code `demo-hyd`). Every value is
synthetic: fake Indian names, phones in `+91 90000 xxxxx`, emails `@demo-seed.example.com`, format-valid fake ABHA
numbers (`91-xxxx-xxxx-xxxx`). No passwords or keys live in this repo.

| File | What it does |
| --- | --- |
| `create-demo-logins.py` | Generates the demo staff logins (`*@demo-seed.example.com`). Writes passwords **only** to a local file outside the repo (default `/workspace/secrets/medicore-demo-logins.txt`, mode 600) and prints SQL containing bcrypt hashes only. Re-running keeps existing passwords. |
| `seed-demo-data.sql` | One transactional `DO` block. Adds branches (only if the tenant has < 3), memberships, 3 practitioners + schedules, 2 service items + prices, 110 patients, 340 appointments (last 90 days + next 7), queue history + today's live queue, bills/discounts/payments (cash, UPI, card)/refunds/unpaid bills via the app's own SQL functions. Writes a manifest to `identity.tenants.settings->'demo_seed'`. |
| `remove-demo-data.sql` | Deletes only the seeded rows (by tags: `@demo-seed.example.com`, `[demo-seed]` reason prefix, manifest ids) and clears the manifest. Supports a dry run. |

## Seed

```bash
python3 scripts/demo/create-demo-logins.py > /tmp/demo-logins.sql   # hashes only; passwords go to the secrets file
psql "$DATABASE_URL" -f /tmp/demo-logins.sql                        # or paste into the Supabase SQL editor
psql "$DATABASE_URL" -f scripts/demo/seed-demo-data.sql
```

The seed is idempotent: if `settings->'demo_seed'->>'version' >= 1` it does nothing.

## Remove

```bash
# dry run (reports counts, rolls back)
psql "$DATABASE_URL" -c "select set_config('demo.dry_run','on',false)" -f scripts/demo/remove-demo-data.sql
# for real
psql "$DATABASE_URL" -f scripts/demo/remove-demo-data.sql
```

Then re-seed with the commands above if wanted.

## Adding data for new features (e.g. visit types)

Do not edit the version-1 block in place. Append a new guarded section (`if version < 2 then ... end if;`)
that adds the new data, records any new ids in the manifest, and bumps `demo_seed.version` to 2. Extend
`remove-demo-data.sql` with matching deletes. Always target the tenant id above.

## Notes

* App functions stamp `now()`, so history is backdated afterwards by updating only timestamp columns with user
  triggers disabled inside the seed transaction. Outbox events for the seed are emitted with the seed time.
* GSTINs are not seeded yet (no column until the GST work lands).
