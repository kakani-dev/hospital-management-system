# Jenkins (optional CI mirror)

The root [`Jenkinsfile`](../../Jenkinsfile) mirrors [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)
for teams that run Jenkins. **GitHub Actions stays the required PR gate**: branch protection and PR checks
are defined there, and this pipeline doesn't replace them.

> Status: the Jenkinsfile was linted (`npm-groovy-lint` 18.0.0: 0 errors; only style warnings such as nesting depth)
> and each command it runs was exercised locally (Vitest JUnit reporter, `dotnet test` filters, self-contained
> gateway publish, Playwright with the prebuilt gateway). It has **not** been executed on a real Jenkins server yet.

## What it runs

| Stage | Agent / containers | Mirrors GitHub job |
|---|---|---|
| Web | `node:24-bookworm`: `npm ci`, ESLint, Vitest (JUnit XML), `vite build` | `web` |
| API | `mcr.microsoft.com/dotnet/sdk:10.0`: restore, build with `-warnaserror`, unit tests (TRX), self-contained gateway publish (stashed for E2E) | `api` |
| Database | `postgres:17` sidecar + `postgres:17` (psql) + .NET SDK: migrations + seed + SQL/RLS tests, then integration + RLS defense-in-depth tests (TRX) | `database` |
| E2E | `postgres:17` sidecar + `mcr.microsoft.com/playwright:v1.63.0-noble`: prepares `hms_e2e`, runs Playwright against web preview + prebuilt API + mock auth (JUnit XML, HTML report archived) | `e2e` |

Web, API and Database run in parallel. E2E runs after them because it needs the stashed gateway build
(the Playwright image has no .NET SDK).

Housekeeping:
- `buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '5'))` keeps the last 10 builds and the artifacts of the last 5.
- `cleanWs()` runs in every stage's `post { cleanup { ... } }`, so agents don't collect old `node_modules`, `bin/obj` or reports.
- `disableConcurrentBuilds(abortPrevious: true)` cancels superseded builds of the same branch.

## Controller and agent requirements

- Jenkins LTS with these plugins: **Pipeline**, **Docker Pipeline** (`docker-workflow`), **JUnit**, **MSTest** (publishes `.trx`),
  **Workspace Cleanup** (`ws-cleanup`), **Timestamper**, and Git/GitHub Branch Source for multibranch jobs.
- At least one agent labelled **`docker`** with Docker Engine available to the Jenkins agent user. Docker-in-Docker isn't needed;
  the pipeline uses sibling containers and `--link` for the Postgres sidecar.
- Outbound network access to pull the images and npm/NuGet packages.
- Image tags live in the `environment` block. Keep `PLAYWRIGHT_IMAGE` in step with `@playwright/test` in the root `package.json`.

## Setting up the job

1. Create a **Multibranch Pipeline** (or a Pipeline job) pointing at the repository. Script path: `Jenkinsfile`.
2. Repository credentials: add a GitHub App or a fine-grained, read-only token as a Jenkins credential
   (*Manage Jenkins → Credentials*) and pick it in the branch source. **Keep credentials in Jenkins**, never in the
   Jenkinsfile or the repo.
3. The pipeline needs **no secrets**. Its databases are throwaway sidecar containers seeded with synthetic data, and the
   local-only `hms_api_login` password comes from `supabase/scripts/local-api-login-role.sql`, which is only used against those containers.
   If you later add deploy stages, read Supabase/Render/Vercel credentials with `withCredentials` from the Jenkins
   credential store. Never point this pipeline at a real Supabase project: `run-sql-tests.sh` drops and recreates its database.
4. Optional: report the build status to GitHub as a non-required check. The required gate stays GitHub Actions.

## Troubleshooting

- **Permission errors inside containers:** `docker.inside` runs as the agent's UID. npm and NuGet caches go to the workspace
  (`npm_config_cache`, `NUGET_PACKAGES`, `DOTNET_CLI_HOME`), so no writable `$HOME` is needed.
- **The gateway fails to start in the Playwright image with an ICU error:** add `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` to the E2E `withEnv` block.
- **Chromium crashes:** the E2E container runs with `--ipc=host`, as Playwright recommends. Check the agent's shared memory if crashes persist.
