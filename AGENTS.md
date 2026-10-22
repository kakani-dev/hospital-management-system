# Agent notes

Before every commit, from the repo root, run:

```bash
bash scripts/verify.sh
```

Do not commit if it fails. Do not skip it because the change looks small.

It runs web lint, unit tests, and the production build only when `apps/web` changed, and `dotnet build` plus unit tests (`Category!=Database`) only when `backend` changed. The diff is this branch against `origin/main`, plus uncommitted and untracked files. Docs, SQL, and workflow-only edits exit 0 without those builds.

`bash scripts/verify.sh --plan` prints which of `web` and `api` would run.

After `npm install` at the repo root, Lefthook runs the same script on `git push` (`lefthook.yml`). The hook does not replace running it before the commit.

See [CONTRIBUTING.md](CONTRIBUTING.md).
