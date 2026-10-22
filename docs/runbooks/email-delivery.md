# Product email (Gmail SMTP)

Invite links, hospital sign-up messages, and invite sign-in codes are queued in `messaging.outbox`
in the same database transaction that creates them, then sent by the identity service. The sender is
`IEmailSender`. Gmail SMTP is the current implementation; a provider such as Resend or SES replaces
that class only.

A brand-new invitee has no `auth.users` row and no password. The invite email contains
`/invite/<token>`. On that page the person asks for a one-time code. `identity.issue_invite_sign_in_code`
stores only a SHA-256 of the code in `identity.email_sign_in_codes` and queues template `sign_in_code`
(the six-digit code and a link whose fragment is `#code=`). The outbox payload is still only
`pending_email_id` and `template_key`. After the code matches, the identity service calls GoTrue's
admin API with the service-role key: create the user if needed (`email_confirm: true`,
`user_metadata.needs_password: true`) and `generate_link` of type `magiclink`. GoTrue does **not**
send that email. The SPA calls `supabase.auth.verifyOtp({ token_hash, type: 'magiclink' })`, then
the invitee chooses their own password (`updateUser`) before they can join. Nobody emails or assigns
a password. Someone who already has a password uses the existing email-and-password form.

Email confirmation, password recovery, email change, and any magic link or email OTP that **GoTrue
itself** sends stay with Supabase Auth. Those codes are created and checked by GoTrue. Pointing
GoTrue at this mailbox is a dashboard step below. This repository does not call the Supabase
management API, and invite acceptance codes do not depend on that dashboard mailer.

Gmail consumer accounts allow about **500 messages a day for the whole mailbox**. The identity worker
stops claiming at `Email:Dispatcher:DailySendLimit` (400) so Auth mail on the same account has room.
Above that volume, replace `IEmailSender`.

The legacy API keeps `Outbox:Dispatcher:Enabled=false` and does not run the mailer (B1).

## Go-live configuration

Nothing here is applied by this change. Deploy stays behind `ACA_DEPLOY_ENABLED` and a reviewer on the
`aca-dev` environment.

### GitHub Actions (repository secret)

| Name | Where it goes | Notes |
|---|---|---|
| `SMTP_PASSWORD` | Deploy workflow on **main** only | Gmail app password for `kakanimohith566@gmail.com`. The owner stores it as a repository secret. Pull requests and fork runs do not receive it. The workflow never prints it. |
| `SUPABASE_SERVICE_ROLE_KEY` | Deploy workflow on **main** only, identity app only | GoTrue service-role key. Used only to turn a checked invite code into a magic-link token hash. Not used to send mail. Never printed, never put in the SPA. |

The workflow writes `SMTP_PASSWORD` to Container App `ca-hms-identity` as secret `smtp-password` and sets
`Smtp__Password=secretref:smtp-password`. It writes `SUPABASE_SERVICE_ROLE_KEY` as secret
`supabase-service-role` and sets `Auth__Supabase__ServiceRoleKey=secretref:supabase-service-role`.
It also sets `Email__Dispatcher__Enabled=true` on that app. If either secret is empty, the identity
deploy step fails and does not roll the image. Patients, scheduling and the edge are not given either secret.

### Identity container app `ca-hms-identity`

Set by the image (`appsettings.json`) plus the deploy workflow:

| Env | Value | Secret? |
|---|---|---|
| `Smtp__Host` | `smtp.gmail.com` | no |
| `Smtp__Port` | `587` | no |
| `Smtp__UseStartTls` | `true` | no |
| `Smtp__Username` | `kakanimohith566@gmail.com` | no |
| `Smtp__FromAddress` | `kakanimohith566@gmail.com` | no |
| `Smtp__FromDisplayName` | `MediCore HMS` | no |
| `Smtp__Password` | `secretref:smtp-password` | yes, from `SMTP_PASSWORD` |
| `Auth__Supabase__ServiceRoleKey` | `secretref:supabase-service-role` | yes, from `SUPABASE_SERVICE_ROLE_KEY` |
| `Email__PublicBaseUrl` | `https://medicore-hms-three.vercel.app` | no |
| `Email__Dispatcher__Enabled` | `true` (workflow, main deploy of identity) | no |
| `Email__Dispatcher__DailySendLimit` | `400` | no |

`Outbox__Dispatcher__Enabled` stays unset or `false` on identity. That dispatcher claims scheduling
events, which this service cannot see.

### Other apps

| App | Required setting |
|---|---|
| `ca-hms-edge`, `ca-hms-patients`, `ca-hms-scheduling` | Do not set `Smtp__Password`, `Email__Dispatcher__Enabled`, or `Auth__Supabase__ServiceRoleKey`. |
| Legacy monolith (`hms_api`) | `Outbox__Dispatcher__Enabled=false`. Do not grant `hms_mailer` or `hms_dispatcher`. |

### Database (hosted Supabase, approval required)

Apply migrations `20261022090000_identity_email_delivery.sql` and `20261022120000_invite_sign_in_codes.sql`
with the normal migration chain. The first creates the NOLOGIN role `hms_mailer` and grants it to
`hms_svc_identity`. No new login password. Existing `hms_identity_login` can `SET ROLE hms_mailer`.
The second adds `identity.email_sign_in_codes` and the issue/consume functions, granted to `hms_mailer`
and `service_role` only (not `anon` or `authenticated`).

### Supabase Auth SMTP (manual dashboard; do not automate)

Project `gvgomzogbzbjhlcsimrx` → **Authentication → Emails → SMTP Settings**:

- Enable custom SMTP.
- Host `smtp.gmail.com`, port `587`, username `kakanimohith566@gmail.com`.
- Sender name `MediCore HMS`, sender email `kakanimohith566@gmail.com`.
- Password: the same Gmail app password, typed into the dashboard. The deploy workflow does not copy it here.
- Confirm signup, reset password, magic link, email change and email OTP templates stay enabled for Auth flows GoTrue itself sends (password recovery, email change, and any magic link a user requests from the login form later).

Invite acceptance codes are **not** those templates. They are sent by the identity worker. That mailbox
then shares the ~500/day Gmail cap between the worker and GoTrue.
