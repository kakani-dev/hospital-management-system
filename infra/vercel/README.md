> **Superseded (25 Oct 2026):** Render is retired; the Render rollback steps here no longer apply. Current deploy: [docs/deploy.md](/docs/deploy.md) and [docs/HANDOVER.md](/docs/HANDOVER.md). Web uses the ACA edge URL as `VITE_API_BASE_URL`.

# Vercel — frontend hosting (apps/web)

**Status: not deployed.** Sprint 0 only adds the configuration.

`vercel.json` here configures the Vite SPA in `apps/web`:

- `framework: vite`, `npm ci`, `npm run build`, output `dist`
- SPA rewrite: every non-file path is served `index.html`, so React Router deep links (`/patients`) work. Vercel serves real files (like `/assets/*.js`) before it applies rewrites.
- Security headers, plus long-lived caching for hashed `/assets/*`.

## Connecting the project (when deployment is approved)

1. In Vercel, import the GitHub repo and set **Root Directory = `apps/web`**.
2. Vercel only reads `vercel.json` from the project's Root Directory. Before the first deploy, copy this file to `apps/web/vercel.json` (or symlink it). It is kept under `infra/` so all hosting config sits in one place. Pick one location and keep it as the single source of truth.
3. Environment variables (Production + Preview):
   - `VITE_API_BASE_URL`: the Render API URL, e.g. `https://hms-api.onrender.com`
   - `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`: **public anon key only**. Never put the service-role key in the frontend.
4. Add the Vercel domain(s) to the API's `Cors__AllowedOrigins__N` on Render.
5. Check Vercel's current Hobby-plan limits and terms before deploying. Hobby is for non-commercial use.

## Production git deploys

`git.deploymentEnabled.main` is false in both `vercel.json` files. A push to `main` does not create a Vercel git deployment. Every other branch still does (pull-request previews). Production is deployed by `.github/workflows/deploy-web.yml` after CI. See [docs/runbooks/deploy-web.md](../../docs/runbooks/deploy-web.md).

Keep `apps/web/vercel.json` and `infra/vercel/vercel.json` identical. Vercel reads `apps/web/vercel.json` because the project Root Directory is `apps/web`.

## TODO
- Add a Content-Security-Policy once the API and Supabase origins are known (`connect-src 'self' <api> <supabase>`).
- Preview deployments must never point at production data.
