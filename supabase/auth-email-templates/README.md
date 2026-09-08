# Supabase Auth email templates

These six files are the **source of truth** for the emails Supabase Auth (GoTrue) sends —
magic link, invite, signup confirmation, email change, password reset, reauthentication.

They are not applied by any migration. GoTrue stores its templates in project config, not in
Postgres, and there is no MCP or SQL path to set them. Paste each file into
**Supabase dashboard → Authentication → Emails → (template) → Source**, then save.

Repeat for every project that serves auth: today `mgtmqucaldkaxvxglguw`, and again on
`hjowfnzpomzxazmzywxw` at cutover.

| File | Dashboard template | Subject line |
|---|---|---|
| `01-confirm-signup.html` | Confirm signup | `Confirm your MUSTER email address` |
| `02-invite-user.html` | Invite user | `You have been invited to MUSTER` |
| `03-magic-link.html` | Magic Link | `Your MUSTER sign-in link` |
| `04-change-email.html` | Change Email Address | `Confirm your new MUSTER email address` |
| `05-reset-password.html` | Reset Password | `Reset your MUSTER password` |
| `06-reauthentication.html` | Reauthentication | `Your MUSTER verification code` |

Variables used are GoTrue's own: `{{ .ConfirmationURL }}`, `{{ .Email }}`, `{{ .NewEmail }}`,
`{{ .Token }}`. They are **not** Resend template variables and do not use Resend's
`{{{ TRIPLE_BRACE }}}` syntax — these templates are rendered by GoTrue and handed to Resend
as finished MIME, over SMTP.

Editing rule: change the file here first, commit, then paste. A template edited only in the
dashboard is lost the next time someone pastes from this directory.

Full routing map, SMTP settings, and redirect allowlist: [`docs/EMAIL.md`](../../docs/EMAIL.md).
