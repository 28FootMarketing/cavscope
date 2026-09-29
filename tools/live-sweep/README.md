# live-sweep

Renders every workspace view in `app.html` three times in Chromium: demo mode,
a live workspace fed one tenant's real payloads, and demo again. It prints, per
view, the lines that are identical in demo and live, and the views that did not
come back to the fresh demo.

An identical line is either a label (fine) or sample content a live tenant is
reading as their own (a defect). The first run, on 2026-09-28, found both
workspace reports broken for every tenant, an accessibility index that was the
security posture relabelled, a dozen fixed claims ("Within Tolerance",
"Formally Approved", "86%"), six record forms that saved nothing, and the demo
showing a tenant's real data after "Show demo". None of it was visible to the
offline suite, which reads source. `tests/ui/live-sweep.test.ts` pins what can
be pinned without a browser; this tool is how to find the next one.

## Run it

1. Build the fixture. Run `fixture.sql` through the Supabase MCP's `execute_sql`
   against the live project, with `:website_id` replaced by a real website id,
   and save the `j` value as `tools/live-sweep/fixture.local.json`.
   **That file is a real tenant's findings, risks and evidence. It is gitignored
   and must never be committed.**
2. `PW_PATH=$(npm root -g)/playwright CHROMIUM=/opt/pw-browsers/chromium-1194/chrome-linux/chrome node tools/live-sweep/sweep.mjs`
   (both variables are optional where Playwright resolves normally).
3. Read `sweep-out.local.json`: `report` holds the identical lines per view,
   `live` the full live text, `notRestored` any view the demo did not get back.

The backend is stubbed per RPC inside the page; an RPC the workspace starts
calling that the stub does not know answers `unstubbed <name>`, which shows up
in the page, so add it to `handlers` in `sweep.mjs` with the fixture's data.
