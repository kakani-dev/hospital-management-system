# MediCore workflow audit — 20 Oct 2026 (IST)

Method: live site (https://medicore-hms-three.vercel.app) read-only page sweep as admin@alpha.example and the
platform master, desktop Chrome + Pixel 7, light + dark (/workspace/qa/audit.mjs, results in
shots/before/audit.json); full-stack local Playwright (55 specs) on a throwaway DB; code review of each screen.

## Bugs
| # | Bug | Repro | Severity | Status |
|---|-----|-------|----------|--------|
| B1 | Pages scroll sideways on phones (Branches +216px, Members +218, Practitioners +316, Working hours +470, Staff schedule +714, Platform requests +492; Staff schedule also +198px on desktop). Edit-branch drawer partly off screen. | Pixel 7 → /admin/branches, swipe left | High (mobile unusable) | Fixed in PR (root cause: `sr-only` header text inside the table scroller had no positioned ancestor, so it escaped `overflow-x-auto` and widened the page) |
| B2 | No follow-up booking: after a visit there is no way to book the next one without re-picking patient and doctor | Queue → Mark done → nothing | High (missing workflow) | Fixed: "Book follow-up" on calendar (checked-in / in consultation / completed) and queue (in room / done) |
| B3 | Branch with no practitioners: booking form shows an empty doctor list with no explanation | Book at a branch with no doctors | Medium | Fixed: empty state + "Add a practitioner" link for admins |
| B4 | Booking error "Choose a practitioner, a free slot and a patient" even when patient chosen; practitioner list | — | Medium | Owned by fix/booking-form (not touched here) |
| B5 | Nav shows links a role can't open (e.g. Patients) | Sign in as lab tech | Medium | Owned by feat/rbac (not touched here) |
| B6 | /api/v1/warmup returns 429 on repeated full page loads (console error, harmless) | Reload pages quickly | Low | Open — the warm-up should be once per session |
| B7 | Invitees have no "create account" screen | Invite link for a new email | High (product gap) | Needs Mohith's decision |
| B8 | Invite links are not emailed | Invite member | Medium | Needs email provider decision |
| B9 | Hospitals can only be suspended, not deactivated | Platform console | Low | Needs decision |

## UX friction (clicks)
| Task | Before | After |
|------|--------|-------|
| Book a follow-up after a visit (queue → booking ready to confirm) | 7–8 (Appointments, Book, pick doctor, type name, pick patient, slot, confirm) | 3 (Book follow-up, slot, confirm) |
| Find out why nothing can be booked at a branch | dead end | 1 (link to Practitioners) |
| Edit a branch on a phone | panel cut off, needs sideways panning | page fits; table scrolls inside its card |
| Register patient from booking search | already inline (no change) | — |

Not done in this pass (would need more time / overlap with in-flight branches): broader UX redesign of
navigation, breadcrumbs, and per-patient "last doctor" default in a fresh booking.
