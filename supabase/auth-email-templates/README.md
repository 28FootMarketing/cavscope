# Supabase Auth email templates

These six files are the **source of truth** for the emails Supabase Auth (GoTrue) sends —
magic link, invite, signup confirmation, email change, password reset, reauthentication.

They are not applied by any migration. GoTrue stores its templates in project config, not in
Postgres, and there is no MCP or SQL path to set them.

**They are applied from CI, not pasted.** Actions → `auth-config` → Run workflow, with
`templates` set to `apply`. It PATCHes all six subjects and bodies through the Management API,
then re-reads the config and compares each body's sha256 against the file here and each subject
exactly. Any disagreement fails the job. Set `templates` to `report` for a read-only listing of
what is live, including `mailer_templates_custom_contents`, which says per template whether it
is customised at all.

`manifest.json` holds the flow name and subject for each file. It is what the workflow reads --
the table below is for humans, and the two are kept in step by hand, so change both.

**Applied to `hjowfnzpomzxazmzywxw` on 2026-09-17**, verified by readback. Before that the six
files had sat here since 2026-09-08 while production served GoTrue stock: the report showed all
six `custom_contents` false and bodies of 124 to 270 characters against roughly 4,700 here. The
README said to paste them, nothing checked whether anyone had, and nobody had. A paying
customer's first contact with MUSTER would have been an unbranded "Confirm your signup" from a
security vendor.

That is the reason this is a workflow now. An instruction to paste is an instruction someone has
to remember; a job that reads the result back is evidence.

| File | Dashboard template | Subject line |
|---|---|---|
| `01-confirm-signup.html` | Confirm signup | `Confirm your MUSTER email address` |
| `02-invite-user.html` | Invite user | `You have been invited to MUSTER` |
| `03-magic-link.html` | Magic Link | `Your secure MUSTER sign-in link` |
| `04-change-email.html` | Change Email Address | `Confirm your new MUSTER email address` |
| `05-reset-password.html` | Reset Password | `Reset your MUSTER password` |
| `06-reauthentication.html` | Reauthentication | `Your MUSTER verification code` |

Variables used are GoTrue's own: `{{ .ConfirmationURL }}`, `{{ .Email }}`, `{{ .NewEmail }}`,
`{{ .Token }}`. They are **not** Resend template variables and do not use Resend's
`{{{ TRIPLE_BRACE }}}` syntax — these templates are rendered by GoTrue and handed to Resend
as finished MIME, over SMTP.

Editing rule: change the file here, commit, then run the workflow. A template edited only in
the dashboard is overwritten on the next apply, and that direction is deliberate -- this
directory is the source of truth, and the dashboard is a cache of it.

Full routing map, SMTP settings, and redirect allowlist: [`docs/EMAIL.md`](../../docs/EMAIL.md).
