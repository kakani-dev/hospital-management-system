# Single-screen workspaces — click audit

Counted from the screens as they work today (October 2026), desktop, for a person who already
knows the task. A click is a pointer activation (a select, a slot, a button, a result). Typing
is not a click. A page switch is a route change. A wait is a loading state the person sits
through before they can continue.

The after column is what this change ships. Playwright (`tests/playwright/mocked/single-screen-workspaces.mocked.spec.ts`)
locks the after path: the route does not change, and the click count stays inside the target.

## (a) Reception — find the patient, book, check in

| | Before | After | Target |
|---|---|---|---|
| Clicks | 8 | 5 | ≤ 6 |
| Page switches | 2 (`/appointments`, then `/reception/check-in`) | 0 (stays on `/appointments`) | 0 |
| Waits | Appointments chunk, slot list, patient search, check-in chunk and list | Patient record and visit list in the drawer (skeleton); slots prefetch with the doctor | No full-page wait |

Before, starting from the dashboard: Appointments → Book → pick the doctor → pick a slot →
search and pick the patient → Confirm → Check-in → Check in the row. Registering someone new
left the drawer for `/patients/new` and came back.

After: Ctrl+K (or the header search) → the patient opens in the side panel on the current
page, with demographics and visits at every branch → Book (current branch, next free slot
already selected) → pick the doctor → Confirm → Check in, still in the panel. "+ New patient"
stays inside the booking drawer and warns about a possible duplicate while the name or phone
is being typed.

## (b) Doctor — my day, the patient, the history, a follow-up

| | Before | After | Target |
|---|---|---|---|
| Clicks | 4, plus a separate trip to the patient page for the history | 3 | ≤ 4 |
| Page switches | 1 (`/queue` → `/appointments` for the follow-up). The chart was another route | 0 (stays on `/queue`) | 0 |
| Waits | Appointments chunk and slot list after leaving the queue | Drawer skeleton, then the visit list; the next slot is selected when it loads | No full-page wait |

Before: on the queue, Book follow-up navigated to the calendar, then a slot and Confirm.
Seeing the history meant opening `/patients/:id`.

After: the name opens the side panel (demographics and every branch's visits, including an
"Other branch" mark). Book follow-up keeps the same panel, with that doctor and the next free
slot filled in. Confirm books it. The queue card's Book follow-up opens that same panel
already on the follow-up form, so the queue never leaves the screen.

## (c) Tenant admin — invite staff and manage branches

| | Before | After | Target |
|---|---|---|---|
| Clicks | 4 (open Members, submit, open Branches, submit) | 2 (submit each form) | ≤ 4 |
| Page switches | 2 (`/admin/members`, `/admin/branches`) | 0 (both forms on `/admin/desk`) | 0 |
| Waits | Two route loads | One desk load; each table keeps its own skeleton | No second page |

Hospital desk is one screen: the existing members form (invite) and the existing branches
form. Members and Branches stay in the navigation for anyone who wants the single list.
Alt+D opens the desk.

## (d) Platform — create a hospital and invite its admin

| | Before | After | Target |
|---|---|---|---|
| Clicks | 2 (Create hospital, then submit) | 2 (the command, then submit) | ≤ 4 |
| Page switches | 0 once on Hospitals; the invite appeared on the same page | 0 (`/platform`, drawer opens from Ctrl+K) | 0 |
| Waits | Drawer mount | Same drawer, opened directly | No page wait |

The create form already collected the hospital and the first admin email and showed the
invite link on the hospitals page. Ctrl+K → "Create hospital" opens that drawer without
hunting for the button. Submitting still shows the invite on `/platform`.

## What changed in the workspace

- Patient side panel on the calendar, the queue, the patient list ("Open here") and Ctrl+K.
  Demographics, tenant-wide visits, book, follow-up and check-in. The route does not change.
- Command palette (Ctrl+K, and the header search button) for a patient or an action.
- Booking drawer: current branch, next free slot preselected, "+ New patient" inline with a
  live duplicate warning. The slot is not put back after a conflict until the doctor or the
  date changes.
- Optimistic appointment row on book (removed if the request fails). Queue moves were
  already optimistic. Skeletons for route loads, the patient panel and the queue.
- Route chunks were already split for scheduling, OPD and the platform. The hospital desk
  is split too. Nav links, dashboard actions and patient names prefetch on hover and focus.
- Shortcuts: Ctrl+K search, Alt+D hospital desk, plus the existing Alt+K / Alt+C / Alt+Q.
- Destructive confirms (cancel a visit, delete a branch or a member) stay. They are the
  only confirmation before a write that cannot be undone from that screen.

## Illustrations

Visual moments (empty states, onboarding and registration, dashboard tiles, success and error
screens) use the open-source [3dicons](https://3dicons.co) library by Vijay Verma (realvjy).
The icons are [CC0](https://creativecommons.org/publicdomain/zero/1.0/). The Figma source is
the community file [3dicons](https://www.figma.com/community/file/1030350068466019692).

Buttons, tables, navigation and inputs keep the existing small Heroicon line icons.

Only the pictures this app shows are stored, under `apps/web/src/assets/illustrations/`.
The published 2× color render is the 400×400 WebP at `dynamic/400/color.webp` (twice the
200px asset) from the 3dicons public storage. Each file was decoded, the opaque white
backdrop was flood-filled from the edges (pixels with red, green and blue at least 248),
and recompressed with libwebp (quality 72, yuva420p). Every file is under 15 KB.
Screens ask for a name through `<Illustration name="…" />` (`Illustration.tsx`); the
component lazy-loads that one file. Paths are not written in screens.

| Name | 3dicons slug | Used for |
|---|---|---|
| calendar | `f32794-calendar` | Dashboard appointments, empty calendar and check-in |
| clock | `8ef1fa-clock` | Waiting tile, empty queue, no free slots |
| person | `a14880-boy` | Registered-today tile, empty patient list, register patient |
| shield | `b91186-shield` | No-access screen |
| lock | `457612-lock` | Sign-in |
| chat | `6afbc7-chat` | Invitation |
| file | `ac021e-file` | Unknown page, invalid invite |
| bell | `ef4a90-bell` | Pending invitations |
| tick | `1b714e-tick` | Checked-in tile, token issued, hospital request received |
| lab | `56180e-lab` | Register a hospital, empty platform list |

There is no neutral “user” glyph in the set, so person is the library’s boy icon.
The bell is `ef4a90-bell`, not the Christmas bell.
