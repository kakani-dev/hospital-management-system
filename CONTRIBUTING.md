# Contributing

## Verify before you commit

From the repo root, before every commit:

```bash
bash scripts/verify.sh
```

That is the local gate. It stays fast by running only what the change touches:

- `apps/web/**` runs web lint, unit tests, and the production build (`npm run lint`, `npm run test`, `npm run build` in `apps/web`).
- `backend/**` runs `dotnet build backend/Hms.slnx -c Release` and the unit tests (`Category!=Database`). Database integration tests stay in CI.
- Docs, SQL, and workflow-only changes run neither and exit 0.

The script looks at the diff from `origin/main` (or `main`) plus anything not yet committed. `bash scripts/verify.sh --plan` prints `web`, `api`, or `none` without running the tools.

## Pre-push hook

Install it once from the repo root:

```bash
npm install
```

That installs [Lefthook](https://github.com/evilmartians/lefthook) and a `pre-push` hook (`lefthook.yml`) which runs `scripts/verify.sh`. A push that fails the check is rejected. The hook is the backstop. Still run the script before you commit, so a failure shows up before the commit exists.

`npm run verify` is the same script.
