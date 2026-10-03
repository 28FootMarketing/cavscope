# Support: how a request moves, and how to work one

## The path

1. A signed-in person uses the **Support** tab (`tools/support/widget.html`, copied into `app.html` and `admin.html`).
2. `cavscope-support-request` files the request in `cavscope.support_requests` under the caller's JWT and emails the `support@` route in `cavscope.mail_routes`, Reply-To the person, screenshot attached.
3. If the **`support_ai`** flag is on (kill switch off, default on) and the function has `MUSTER_OPENROUTER_API_KEY` or `OPENROUTER_API_KEY`, a model reads the request, the screenshot and a few account facts, and support gets a second email: summary, what is on screen, likely cause, suggested fix and a **draft** reply. The model's words go to support only. Nothing it writes reaches the customer unread.

The model defaults to `anthropic/claude-sonnet-4.5` on OpenRouter; set `CAVSCOPE_SUPPORT_AI_MODEL` on the function to change it. Verify the first real run: the model slug is a setting, and an unknown one shows up as `ai_status = 'failed'` with `ai_error = 'model 400'`.

## What is stored, and what is not

`support_requests` keeps the message, category, page address, browser, window size and, when AI ran, the model's notes (`ai_*`). **The screenshot is never stored**, and the model is told to describe the interface state only (page, panel, error text) and not to copy personal data. `ai_status` is `pending`, `done`, `failed` or `skipped` (no key); it is null while the flag is dark.

## Working a request (the self-healing path)

The fix is not automatic and should not be. A person, or a Claude Code session working for one, does this:

1. Read the request: `select * from cavscope.support_requests where id = <n>` (Supabase MCP, project `hjowfnzpomzxazmzywxw`). The screenshot is in the support inbox email, not the database.
2. Read the `ai_*` notes as a lead, not a finding. A model can misread a screen.
3. Reproduce. For a "looks wrong" report, `tools/live-sweep/` renders a workspace from a tenant's real payloads; `tools/local-scan/` runs the scan rules against a URL with no database.
4. Fix on a branch, open a PR, let CI run, merge. A fix that changes what a tenant sees confirms first.
5. Reply from the support inbox. Start from `ai_draft_reply` if it is right; edit it if it is not. Do not promise dates, refunds or credits, and route legal, tax, compliance, contract and billing questions to the right person.

Add a fully automatic path only after the notes have proven reliable on real requests. An auto-fix to a security product that is wrong costs more than a slow one.
