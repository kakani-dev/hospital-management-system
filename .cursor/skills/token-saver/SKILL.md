---
name: token-saver
description: Use on any task in this repo to keep token usage low while still verifying the work.
---
# Token saver

1. **Locate first.** Map the area with `rg -l '<term>' backend/ apps/web/src supabase/` and `git ls-files <dir>`; open only the 1-3 files that matter.
2. **Read narrowly.** Read the function or range you need, not the whole file. Skim large files with `rg -n` for anchors first.
3. **Know the layout** (so you don't explore):
   - `backend/services/<svc>` hosts, `backend/modules/<Module>` domain code, `backend/edge/Hms.Edge` gateway routes (`appsettings.json`), `backend/shared` kernel.
   - `apps/web/src` React + TS (Tailux demo2 components), `supabase/migrations` SQL, `supabase/tests` SQL tests, `tests/playwright` E2E.
4. **Test what you touched.** Backend: `dotnet test` on the affected test project. Web: `npm --prefix apps/web run test -- <pattern>`. SQL: only the related test file. Full run (`scripts/verify.sh`) once before the PR.
5. **Quiet output.** Use `--quiet`, `-q`, `--reporter=dot`, and `| tail -n 50`. Never dump whole logs or lockfiles.
6. **Write less.** Small focused diffs, no reformatting of untouched code, short PR descriptions (what, why, tests, risks).
7. **Don't loop.** If the same fix fails twice, stop, read the error once more carefully, then change approach.
