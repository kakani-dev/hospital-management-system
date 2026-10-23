# Deploy the web app to Vercel

Production for project `medicore-hms` (team `kakani-devs-projects`, Hobby plan) is deployed by GitHub Actions. The live site is `https://medicore-hms-three.vercel.app`.

## Why git production deploys are off

The Hobby team has one member, `kakani-dev`. A squash-merge onto `main` is authored by GitHub account `kakani17481a0566`. Vercel then refuses the git production deployment: "Git author kakani17481a0566 must have access to the project on Vercel to create deployments." The commit status is "Deployment was blocked."

Preview deployments from pull requests by that same account complete. `apps/web/vercel.json` sets `git.deploymentEnabled.main` to false and leaves every other branch enabled. Vercel reads that file because the project Root Directory is `apps/web`. `infra/vercel/vercel.json` is the same document, kept next to the other host config. The two files stay identical.

With `main` disabled, a push to `main` does not create a Vercel git deployment, so it does not create a blocked one. Preview branches still deploy through the git integration.

## What runs on its own

1. Push to `main`.
2. The `CI` workflow passes for that push. A nightly run and a manual CI run do not deploy.
3. `Deploy web to Vercel` plans the commit. It deploys when the commit touches `apps/web/**`, `infra/vercel/**`, or `.github/workflows/deploy-web.yml`. API, SQL, and docs commits do not deploy the web app.
4. A newer production deploy cancels one that has not finished (`deploy-web`, cancel-in-progress). The path check sits outside that group, so a main push that does not touch the web app does not cancel a deploy already running.
5. From the repo root the job runs `vercel pull --yes --environment=production`, `vercel build --prod`, and `vercel deploy --prebuilt --prod`. The CLI is pinned at 65.1.0. Node is 24, the same as the frontend CI job. The project's Root Directory `apps/web` is applied once because the commands run at the repo root.
6. The job requests `https://medicore-hms-three.vercel.app` until it returns HTTP 200. Any other result runs `vercel rollback --yes` and fails the job. On the Hobby plan that rolls production back to the previous production deployment. The command takes no deployment id.

`workflow_dispatch` from `main` deploys the current tip even when those paths did not change.

```bash
gh workflow run "Deploy web to Vercel" --ref main
```

Nothing in the workflow waits on a GitHub environment reviewer.

## GitHub secrets

Set these three repository secrets on `kakani-dev/hospital-management-system` before the first production run. Do not commit the values. Do not put them in the workflow file. `.vercel/` is gitignored because `vercel pull` writes environment files there.

The token has to be created by the Hobby team owner (the Vercel account linked to GitHub `kakani-dev`). A token from `kakani17481a0566` cannot deploy this project.

| Secret | Required | Where to copy it from |
|---|---|---|
| `VERCEL_TOKEN` | yes | Vercel → Account Settings → Tokens, while logged in as the team owner. Scope it to team `kakani-devs-projects` when the token form offers a team. |
| `VERCEL_ORG_ID` | yes | Team `kakani-devs-projects` → Settings → General → Team ID. |
| `VERCEL_PROJECT_ID` | yes | Project `medicore-hms` → Settings → General → Project ID. |

`gh secret set` reads the value from stdin. Paste it, then press Enter, then Ctrl-D. The value does not belong in the command line.

```bash
REPO=kakani-dev/hospital-management-system
gh secret set VERCEL_TOKEN --repo "$REPO"
gh secret set VERCEL_ORG_ID --repo "$REPO"
gh secret set VERCEL_PROJECT_ID --repo "$REPO"
```

The merge that adds this workflow is the first Actions deploy, when CI on that push is green and the commit touches `apps/web`. If a secret is missing, that deploy fails. Git does not deploy `main`, and the previous production deployment stays up. Set the secrets and run the workflow again from `main`.

## Manual rollback

From a machine logged in as the team owner, with this repo as the current directory and `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`, and `VERCEL_TOKEN` set:

```bash
vercel rollback --yes
```

Hobby rolls back one production deployment. Rolling further back needs a Pro team.
