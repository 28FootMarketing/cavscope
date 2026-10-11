// Renders /admin SIGNED IN against a synthetic fixture and runs axe-core on every section, because
// tools/site-axe/run.mjs cannot: signed out, /admin bounces to the landing page and reports its numbers.
// The fixture is invented (no customer data); the Supabase client is replaced by a stub that serves it.
// Nothing is written anywhere and no network call reaches Supabase.
//
//   cd workers/browser-scan && npm install      (once)
//   node tools/site-axe/admin.mjs               every section
//   DETAIL=1 node tools/site-axe/admin.mjs      the failing elements
//
// Covers what the fixture draws: the shell, the nav, every section's tables, forms and empty states.
// Does not cover a state the fixture does not reach (a failed side read, an open modal).
import { readFileSync } from "node:fs";
import { chromium } from "../../workers/browser-scan/node_modules/playwright-core/index.mjs";
import { createRequire } from "node:module";
const R = new URL("../..", import.meta.url).pathname.replace(/\/$/, "");
const axeSrc = readFileSync(createRequire(import.meta.url).resolve(`${R}/workers/browser-scan/node_modules/axe-core/axe.min.js`), "utf8");
const ORIGIN = "https://cavscope.28footsystems.com";
const now = new Date().toISOString();
const org = (id, name, extra = {}) => ({ id, name, plan: "pro", industry: "Technology", is_admin_sandbox: false, onboarding_status: "complete", jurisdiction: "US-PA", members: 2, websites: 1, open_critical: 0, open_high: 1, worst_score: 74, last_scan_at: now, created_at: now, website_limit: 5, client_orgs: 0, partner_client_allowance: null, managed_by: null, ...extra });
const site = (id, o) => ({ id, name: `site-${id}`, url: `https://site${id}.example.org`, organization_id: o.id, organization: o.name, verified: true, score: 74, band: "amber", open_critical: 0, open_high: 1, open_medium: 2, open_low: 1, last_scan_at: now, cadence: "daily", is_admin_sandbox: false });
const o1 = org(1, "Example Org"), o2 = org(2, "Sandbox", { is_admin_sandbox: true, plan: "trial" });
const CONSOLE = {
  kpi: { api: { keys_total: 4, keys_active: 1, instrumented: false, requests_30d: null, keys_used_24h: 0 }, revenue: { basis: "plan_implied", billed: false, mrr_cents: 4900, paying_orgs: 1, unpriced_orgs: 1 }, high_risk: { high: 1, open: 1, new_24h: 0, critical: 0, orgs_affected: 1 }, compliance: { met: 136, rate: 68, total: 199, manual: 2, not_met: 4, partial: 59, assessed: 199, unassessed: 0, not_applicable: 0 }, assessments: { queued: 0, running: 0, failed_24h: 0, complete_7d: 47, complete_24h: 5 }, organizations: { total: 2, new_30d: 0, sandbox: 1, onboarding: 0 } },
  flags: [{ key: "manual_scans", name: "Manual scans", scope: "organization", surface: "On-demand scan", category: "engine", overrides: 0, description: "Members can request an on-demand scan.", enforcement: ["sql"], kill_switch: false, plan_minimum: "trial", default_enabled: true }, { key: "commercial_use_enabled", name: "Commercial use", scope: "organization", surface: "Licence term", category: "partner", overrides: 0, description: "A licence term.", enforcement: [], kill_switch: false, plan_minimum: "pro", default_enabled: true }],
  stage: "seed", users: [{ id: 1, email: "owner@example.org", role: "super_admin", organization: "Example Org", organization_id: 1, last_sign_in_at: now, created_at: now }, { id: 2, email: "member@example.org", role: "viewer", organization: "Example Org", organization_id: 1, last_sign_in_at: null, created_at: now }],
  system: { incidents: { open: 0, items: [] }, queue: { queued: 0, running: 0, oldest_queued_at: null }, cron: [{ jobname: "cavscope-scan-due-15min", schedule: "*/15 * * * *", active: true, last_status: "succeeded", last_run_at: now }], engine_version: "http-native-1.14.0", cron_failures_24h: 0 },
  pricing: { stage: "seed", muster: { seed: 49, fruit: 79 }, partner: { seed: 199, fruit: 299 }, visible: { muster: true, partner: true, enterprise: true }, cta: {} },
  activity: [{ id: 1, kind: "scan", title: "Scan completed", organization: "Example Org", organization_id: 1, created_at: now, detail: "0 new" }],
  websites: [site(1, o1), site(2, o2)], cron_http: { total: 4, failed: 0, window_hours: 24 }, org_health: [], risk_watch: [{ id: 1, title: "Missing HSTS", severity: "high", organization: "Example Org", organization_id: 1, website: "site1.example.org", rule_id: "SEC-001", created_at: now, status: "open" }],
  plan_limits: { trial: 1, pro: 5 }, action_items: [{ kind: "scan", title: "Review a high risk", section: "audit-queue", severity: "high" }], flag_changes: [], generated_at: now, integrations: { stripe: { grants_total: 1, pending: 0, applied: 1, cancelled: 0, last_grant_at: now, last_webhook_at: now }, resend: { sent_24h: 1, bounced_24h: 0, suppressed: 0, last_event_at: now } },
  recent_scans: [{ id: 1, organization: "Example Org", organization_id: 1, website: "site1.example.org", website_id: 1, status: "complete", trigger: "scheduled", score: 74, band: "amber", engine_version: "http-native-1.14.0", created_at: now, finished_at: now, error_message: null }],
  role_changes: [], organizations: [o1, o2], pricing_changes: [], compliance_by_framework: [{ framework: "owasp_top10", label: "OWASP Top 10", met: 10, partial: 2, not_met: 1, not_assessed: 0, not_applicable: 0, total: 13, rate: 77 }],
};
const SIDE = {
  cavscope_admin_flag_registry: CONSOLE.flags.map((f) => ({ ...f, id: f.key })), cavscope_admin_impersonate_status: { active: false }, cavscope_admin_impersonation_log: [],
  cavscope_admin_overview: { incidents: [] }, cavscope_admin_platform_extras: { agents: [], jurisdiction_review: [] }, cavscope_admin_site_jurisdictions: [], cavscope_admin_partner_allowances: [], cavscope_admin_aio_overview: { rules: [{ rule: "GOV-006", title: "llms.txt", pillar: "discoverability", active: true }, { rule: "GOV-007", title: "Structured data", pillar: "structure", active: true }],
    sites: [{ website: "site1.example.org", url: "https://site1.example.org", organization: "Example Org", organization_id: 1, sandbox: false, index: 50, passed: 1, assessed: 2, scan_id: 1, scanned_at: now, checks: [{ rule: "GOV-006", state: "pass" }, { rule: "GOV-007", state: "fail", detail: "No JSON-LD." }] }, { website: "site2.example.org", url: "https://site2.example.org", organization: "Sandbox", organization_id: 2, sandbox: true, index: null, scan_id: null, checks: [] }] },
  cavscope_admin_sitreps: [{ id: 7, website: "site1.example.org", url: "https://site1.example.org", headline: "site1.example.org: posture 74/100 (amber)", organization: "Example Org", organization_id: 1, is_admin_sandbox: false, posture_score: 74, posture_band: "amber", generator: "deterministic-v1", engine_version: "http-native-1.14.0", citations: 6, generated_at: now }],
  cavscope_admin_sitrep: { id: 7, posture_score: 74, posture_band: "amber", generator: "deterministic-v1", engine_version: "http-native-1.14.0", generated_at: now, content_md: "# Report\n\nBody.", content_sha256: "ab".repeat(32), headline: "site1.example.org" },
  cavscope_scans: [],
  cavscope_admin_workspaces: [
    { organization_id: 1, name: "Example Org", plan: "pro", is_sandbox: false, onboarding_status: "complete", created_at: now, last_activity_at: now, managed_by: null,
      partner: { allowance: 3, clients_used: 1, clients: [{ id: 3, name: "Client One" }] },
      team: { members: 3, by_role: { executive: 1, viewer: 2 }, pending_invites: 1, last_sign_in: now },
      sites: { registered: 3, limit: 5, verified: 1, scheduled: 2, scanned: 2, cadence_minutes: 1440, last_scan_at: now },
      access: { keys_active: 1, keys_total: 2, keys_last_used: now, agents_active: 1 },
      ai: { configured: true, enabled: true, label: "Provider", model: "model-x", last_ok_at: now, last_error_at: null, last_error: null },
      brand: { mode: "white-label", name: "Agency Co", custom_domain: "reports.agency.example" },
      alerts: { critical: true, sitrep_ready: false, custom_recipients: 2 }, overrides: 2,
      gaps: ["2 of 3 sites have not proven ownership.", "1 of 3 sites have no completed scan."] },
    { organization_id: 3, name: "Client One", plan: "pro", is_sandbox: false, onboarding_status: "complete", created_at: now, last_activity_at: null, managed_by: { id: 1, name: "Example Org" },
      partner: { allowance: null, clients_used: 0, clients: [] },
      team: { members: 1, by_role: { executive: 1 }, pending_invites: 0, last_sign_in: null },
      sites: { registered: 1, limit: 5, verified: 1, scheduled: 1, scanned: 1, cadence_minutes: 60, last_scan_at: now },
      access: { keys_active: 0, keys_total: 0, keys_last_used: null, agents_active: 0 },
      ai: { configured: true, enabled: true, label: "Provider", model: "model-x", last_ok_at: null, last_error_at: now, last_error: "401 invalid key <b>x</b>" },
      brand: { mode: "default", name: null, custom_domain: null },
      alerts: { critical: true, sitrep_ready: true, custom_recipients: 0 }, overrides: 0, gaps: ["The AI provider's last call failed."] },
    { organization_id: 2, name: "Sandbox", plan: "trial", is_sandbox: true, onboarding_status: "complete", created_at: now, last_activity_at: now, managed_by: null,
      partner: { allowance: null, clients_used: 0, clients: [] },
      team: { members: 1, by_role: { executive: 1 }, pending_invites: 0, last_sign_in: now },
      sites: { registered: 1, limit: 1000, verified: 0, scheduled: 1, scanned: 1, cadence_minutes: 1440, last_scan_at: now },
      access: { keys_active: 0, keys_total: 0, keys_last_used: null, agents_active: 0 },
      ai: { configured: false }, brand: { mode: "co-branded", name: "28 Foot Systems", custom_domain: null },
      alerts: { critical: true, sitrep_ready: false, custom_recipients: 0 }, overrides: 0, gaps: [] },
  ],
  cavscope_admin_domain_monitor: { generated_at: now, window_days: 30, sites: [
    { website_id: 1, website: "site1.example.org", url: "https://site1.example.org", organization_id: 1, organization: "Example Org", sandbox: false, scanned: true, scan_id: 1, scanned_at: now, engine_version: "http-native-1.14.0", scan_enabled: true, cadence_minutes: 1440, domain: "site1.example.org",
      mx: { state: "present", records: ["1 smtp.example.org."] }, spf: { state: "present", value: "v=spf1 include:_spf.example.org ~all", lookups: 2 }, dmarc: { state: "reject", value: "v=DMARC1; p=reject" },
      caa: { state: "present" }, dnssec: { state: "on" }, mta_sts: { state: "present" }, hsts: { state: "present", value: "max-age=31536000", max_age: 31536000 },
      certificate: { state: "ok", host: "site1.example.org", not_after: "2027-01-01T00:00:00Z", days_remaining: 60, issuer: "Example CA <i>x</i>", names: 2, self_signed: false, tls_version: "TLS 1.2" },
      changes_30d: 2, recent_changes: [{ record: "DMARC", at: now, from: "no DMARC at _dmarc.site1.example.org", to: "v=DMARC1; p=reject <script>x</script>", engine_changed: false }, { record: "SPF", at: now, from: "(none)", to: "v=spf1 -all", engine_changed: true }] },
    { website_id: 2, website: "site2.example.org", url: "https://site2.example.org", organization_id: 1, organization: "Example Org", sandbox: false, scanned: true, scan_id: 2, scanned_at: "2026-01-01T00:00:00Z", engine_version: "http-native-1.14.0", scan_enabled: false, cadence_minutes: null, domain: "site2.example.org",
      mx: { state: "none" }, spf: { state: "missing" }, dmarc: { state: "missing" }, caa: { state: "none" }, dnssec: { state: "off" }, mta_sts: { state: "none" }, hsts: { state: "absent" }, certificate: { state: "ok", host: "site2.example.org", not_after: "2026-01-01T00:00:00Z", days_remaining: -3, issuer: "Example CA", names: 1, self_signed: true, tls_version: "TLS 1.2" }, changes_30d: 0, recent_changes: [] },
    { website_id: 3, website: "site3.example.org", url: "https://site3.example.org", organization_id: 1, organization: "Example Org", sandbox: false, scanned: true, scan_id: 3, scanned_at: now, engine_version: "http-native-1.14.0", scan_enabled: true, cadence_minutes: 1440, domain: "site3.example.org",
      mx: { state: "present", records: ["1 a.", "2 b."] }, spf: { state: "multiple" }, dmarc: { state: "monitor", value: "v=DMARC1; p=none" }, caa: { state: "not_observed" }, dnssec: { state: "not_observed" }, mta_sts: { state: "not_observed" }, hsts: { state: "not_observed" }, certificate: { state: "unavailable", reason: "requires_tls13" }, changes_30d: 0, recent_changes: [] },
    { website_id: 4, website: "site4.example.org", url: "https://site4.example.org", organization_id: 2, organization: "Sandbox", sandbox: true, scanned: false, scan_id: null, scanned_at: null, engine_version: null, scan_enabled: true, cadence_minutes: 1440, domain: null,
      mx: { state: "not_observed" }, spf: { state: "not_observed" }, dmarc: { state: "not_observed" }, caa: { state: "not_observed" }, dnssec: { state: "not_observed" }, mta_sts: { state: "not_observed" }, hsts: { state: "not_observed" }, changes_30d: 0, recent_changes: [] },
  ] },
};
const STUB = `window.supabase={createClient:function(){var s={user:{email:'owner@example.org',app_metadata:{}},access_token:'x'};
return{auth:{getSession:function(){return Promise.resolve({data:{session:s}})},onAuthStateChange:function(){return{data:{subscription:{unsubscribe:function(){}}}}},signOut:function(){return Promise.resolve({})}},
rpc:function(n,a){return fetch('/__rpc/'+n).then(function(r){return r.json()}).then(function(d){return d&&d.__error?{data:null,error:{message:d.__error}}:{data:d,error:null}})},
from:function(){var q={select:function(){return q},eq:function(){return q},order:function(){return q},limit:function(){return q},then:function(f){return Promise.resolve({data:[],error:null}).then(f)}};return q}}}};`;
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 } });
await ctx.route(/^https?:/, async (route) => {
  const u = new URL(route.request().url());
  if (u.origin === ORIGIN) {
    if (u.pathname.startsWith("/__rpc/")) { const n = u.pathname.slice(7); return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(n === "cavscope_admin_console" ? CONSOLE : (SIDE[n] ?? null)) }); }
    return route.fulfill({ status: 200, contentType: "text/html", body: readFileSync(`${R}/admin.html`, "utf8").replace(/(supabase\.min\.js")\s+integrity="[^"]*"/, "$1") });
  }
  if (/supabase\.min\.js/.test(u.pathname)) return route.fulfill({ status: 200, contentType: "text/javascript", body: STUB });
  if (/supabase\.co/.test(u.host)) return route.abort("blockedbyclient");
  try { const res = await fetch(u.toString()); return route.fulfill({ status: res.status, contentType: res.headers.get("content-type") ?? "text/plain", body: Buffer.from(await res.arrayBuffer()) }); } catch { return route.abort("failed"); }
});
const page = await ctx.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(String(e.message).slice(0, 200)));
await page.goto(`${ORIGIN}/admin`, { waitUntil: "networkidle" });
await page.waitForSelector("#shell:not([hidden])", { timeout: 15000 }).catch(() => {});
await page.evaluate(axeSrc);
const sections = await page.$$eval("#nav button[data-section]", (b) => b.map((x) => x.dataset.section));
let bad = 0;
for (const id of sections) {
  const before = errors.length;
  await page.click(`#nav button[data-section="${id}"]`);
  await page.mouse.move(700, 880); await page.keyboard.press("Escape"); await page.waitForTimeout(150);
  const cnt = await page.evaluate(() => ({ t: document.querySelectorAll("#page table").length, r: document.querySelectorAll("#page tbody tr").length, b: document.querySelectorAll("#page button").length, f: document.querySelectorAll("#page select,#page input,#page textarea").length }));
  const res = await page.evaluate(async () => { const r = await axe.run(document, { resultTypes: ["violations"] }); return r.violations.map((v) => ({ id: v.id, impact: v.impact, n: v.nodes.length, help: v.help, nodes: v.nodes.slice(0, 3).map((n) => `${n.target.join(" ")} :: ${n.html.slice(0, 120).replace(/\s+/g, " ")} :: ${n.failureSummary.replace(/\s+/g, " ").slice(0, 160)}`) })); });
  const errs = errors.slice(before);
  if (res.length || errs.length) bad++;
  console.log(`${id.padEnd(18)} [t${cnt.t} r${cnt.r} b${cnt.b} f${cnt.f}] ${res.length ? res.map((v) => `${v.id}(${v.n},${v.impact})`).join(" ") : "no violations"}${errs.length ? "  SCRIPT ERROR: " + errs.join(" | ") : ""}`);
  if (process.env.DETAIL) for (const v of res) { console.log(`   ## ${v.help}`); v.nodes.forEach((x) => console.log("     ", x)); }
}
{ await page.click('#nav button[data-section="reports"]'); await page.click("tr[data-sitrep]").catch(() => {}); await page.waitForTimeout(200); await page.mouse.move(700, 880); await page.keyboard.press("Escape");
  const res = await page.evaluate(async () => (await axe.run(document, { resultTypes: ["violations"] })).violations.map((v) => `${v.id}(${v.nodes.length},${v.impact})`));
  if (res.length) bad++; console.log(`${"reports:detail".padEnd(18)} ${res.length ? res.join(" ") : "no violations"}`); }
{ // The support tab opens a (non-modal) dialog on the right edge; scan it open.
  await page.evaluate(() => { const t = document.getElementById("csSupportTab"); if (t) t.click(); });
  await page.waitForFunction(() => { const p = document.getElementById("csSupportPanel"); return p && !p.hidden; }, null, { timeout: 8000 }).catch(() => {});
  const open = await page.evaluate(() => !document.getElementById("csSupportPanel").hidden);
  const res = open ? await page.evaluate(async () => (await axe.run({ exclude: [["#appTooltip"]] }, { resultTypes: ["violations"] })).violations.map((v) => `${v.id}(${v.nodes.length},${v.impact})`)) : ["did not open"];
  const dlg = await page.evaluate(() => document.getElementById("csSupportPanel").getAttribute("role") === "dialog");
  await page.keyboard.press("Escape"); await page.waitForTimeout(150);
  const esc = await page.evaluate(() => document.getElementById("csSupportPanel").hidden);
  const gaps = [!dlg && "no dialog role", !esc && "Escape does not close"].filter(Boolean);
  if (res.length || gaps.length) bad++; console.log(`${"support panel".padEnd(18)} ${res.length ? res.join(" ") : "no violations"}${gaps.length ? "  | " + gaps.join(", ") : ""}`); }
{ // DNS text and provider errors are third-party content: the fixture plants markup in both, and it must print as text.
  const probe = async (id, needle) => { await page.click(`#nav button[data-section="${id}"]`); await page.waitForTimeout(150);
    return page.evaluate((n) => { const el = document.getElementById("page"); return { shown: el.innerText.includes(n), injected: !!el.querySelector("script") || el.innerHTML.includes(n) }; }, needle); };
  const a = await probe("domain-monitor", "<script>x</script>"), b = await probe("workspaces", "<b>x</b>");
  const ok = a.shown && !a.injected && b.shown && !b.injected;
  if (!ok) bad++;
  console.log(`${"escaping".padEnd(18)} ${ok ? "hostile DNS text and provider error print as text" : `FAILED domain ${JSON.stringify(a)} workspaces ${JSON.stringify(b)}`}`); }
if (process.env.PEEK) for (const id of process.env.PEEK.split(",")) { await page.click(`#nav button[data-section="${id}"]`); await page.waitForTimeout(150); console.log("\n## " + id + ": " + (await page.evaluate(() => document.getElementById("page").innerText)).replace(/\s+/g, " ").slice(0, 500)); }

// States the default fixture does not reach, scanned across every section: a super admin with a support-access session
// open (banner, countdown, the target's view, a populated log), and the console with every side read failing (each panel
// that depends on one must say so instead of showing nothing).
async function scanState(tag, mutate) {
  const saved = { ...SIDE };
  mutate();
  await page.reload({ waitUntil: "networkidle" });
  await page.waitForSelector("#shell:not([hidden])", { timeout: 15000 }).catch(() => {});
  await page.evaluate(axeSrc);
  const before = errors.length;
  const out = [];
  for (const id of sections) {
    await page.click(`#nav button[data-section="${id}"]`);
    await page.mouse.move(700, 880); await page.keyboard.press("Escape"); await page.waitForTimeout(250);
    const full = await page.evaluate(async () => (await axe.run({ exclude: [["#appTooltip"]] }, { resultTypes: ["violations"] })).violations.map((v) => ({ s: `${v.id}(${v.nodes.length},${v.impact})`, nodes: v.nodes.slice(0, 3).map((n) => `${n.target.join(" ")} :: ${n.html.slice(0, 110).replace(/\s+/g, " ")} :: ${n.failureSummary.replace(/\s+/g, " ").slice(0, 170)}`) })));
    const res = full.map((v) => v.s);
    if (res.length) { bad++; out.push(`${id}: ${res.join(" ")}`); if (process.env.DETAIL) full.forEach((v) => v.nodes.forEach((n) => console.log("     ", n))); }
  }
  const errs = errors.slice(before);
  if (errs.length) { bad++; out.push("SCRIPT ERROR: " + errs.join(" | ")); }
  console.log(`${tag.padEnd(26)} ${out.length ? out.join(" ; ") : `${sections.length} sections, no violations`}`);
  Object.keys(SIDE).forEach((k) => delete SIDE[k]); Object.assign(SIDE, saved);
}
await scanState("support session open", () => {
  SIDE.cavscope_admin_impersonate_status = { active: true, target_user_id: 2, target_email: "member@example.org", reason: "ticket 412, cannot see their SITREP", seconds_remaining: 1200 };
  SIDE.cavscope_admin_impersonation_log = [{ admin_email: "owner@example.org", target_email: "member@example.org", reason: "ticket 412", started_at: now, events: 3, active: true }, { admin_email: "owner@example.org", target_email: "viewer@example.org", reason: "earlier ticket", started_at: now, events: 1, active: false, ended_reason: "expired" }];
  SIDE.cavscope_admin_impersonated_view = { organizations: [{ name: "Example Org", role: "viewer", websites: [{ url: "https://site1.example.org", posture_score: 74, open_critical_high: 1, open_findings: 4 }] }] };
});
await scanState("side reads failing", () => {
  for (const k of ["cavscope_admin_flag_registry", "cavscope_admin_impersonate_status", "cavscope_admin_impersonation_log", "cavscope_admin_overview", "cavscope_admin_platform_extras", "cavscope_admin_site_jurisdictions", "cavscope_admin_partner_allowances", "cavscope_admin_aio_overview"]) SIDE[k] = { __error: "permission denied for function (fixture)" };
});
if (!sections.length) { console.log("shell never rendered", errors.join(" | "), "| gate:", await page.evaluate(() => document.getElementById("gateLoadingMsg")?.textContent + " denied=" + !document.getElementById("gateDenied")?.hidden + " url=" + location.href)); bad++; }
await browser.close();
process.exit(bad ? 1 : 0);
