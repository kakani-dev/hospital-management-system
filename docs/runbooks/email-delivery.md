# Product email (Gmail SMTP)

Invite links and hospital sign-up messages are queued in `messaging.outbox` in the same database
transaction that creates them, then sent by the identity service. The sender is `IEmailSender`.
Gmail SMTP is the current implementation; a provider such as Resend or SES replaces that class only.

Sign-in, email confirmation, password recovery, email change and email OTP stay with **Supabase Auth**.
GoTrue creates those codes and checks them when it issues a session. An application-generated code
would not be accepted by `/auth/v1/token` or `/verify`, so it would not actually verify the account.
Pointing GoTrue at this mailbox is a dashboard step below. This repository does not call the Supabase
management API.

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

The workflow writes that value to Container App `ca-hms-identity` as secret `smtp-password` and sets
`Smtp__Password=secretref:smtp-password`. It also sets `Email__Dispatcher__Enabled=true` on that app.
Patients, scheduling and the edge are not given the secret.

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
| `Email__PublicBaseUrl` | `https://medicore-hms-three.vercel.app` | no |
| `Email__Dispatcher__Enabled` | `true` (workflow, main deploy of identity) | no |
| `Email__Dispatcher__DailySendLimit` | `400` | no |

`Outbox__Dispatcher__Enabled` stays unset or `false` on identity. That dispatcher claims scheduling
events, which this service cannot see.

### Other apps

| App | Required setting |
|---|---|
| `ca-hms-edge`, `ca-hms-patients`, `ca-hms-scheduling` | Do not set `Smtp__Password` or `Email__Dispatcher__Enabled`. |
| Legacy monolith (`hms_api`) | `Outbox__Dispatcher__Enabled=false`. Do not grant `hms_mailer` or `hms_dispatcher`. |

### Database (hosted Supabase, approval required)

Apply migration `20261022090000_identity_email_delivery.sql` with the normal migration chain.
It creates the NOLOGIN role `hms_mailer` and grants it to `hms_svc_identity`. No new login password.
Existing `hms_identity_login` can `SET ROLE hms_mailer`.

### Supabase Auth SMTP (manual dashboard; do not automate)

Project `gvgomzogbzbjhlcsimrx` → **Authentication → Emails → SMTP Settings**:

- Enable custom SMTP.
- Host `smtp.gmail.com`, port `587`, username `kakanimohith566@gmail.com`.
- Sender name `MediCore HMS`, sender email `kakanimohith566@gmail.com`.
- Password: the same Gmail app password, typed into the dashboard. The deploy workflow does not copy it here.
- Confirm signup, reset password, magic link, email change and email OTP templates stay enabled for whatever Auth flows the project uses.

That mailbox then shares the ~500/day Gmail cap with the identity worker.
