// Renders the WORKSPACE (/app) in Chromium twice, signed out (demo data) and signed in as a synthetic
// tenant, and runs axe-core on every view. tools/site-axe/run.mjs cannot: it sees /app only as the
// signed-out page, and a live tenant's panels are built from RPC payloads it never receives.
// The fixture is invented (no customer data); the Supabase client is replaced by a stub that serves it.
// Nothing is written anywhere and no call reaches Supabase.
//
//   cd workers/browser-scan && npm install      (once)
//   node tools/site-axe/app.mjs                 demo + live, every view
//   DETAIL=1 node tools/site-axe/app.mjs        the failing elements
//   FIXTURE=tools/live-sweep/fixture.local.json node tools/site-axe/app.mjs
//       a real tenant's payloads, if you built that gitignored file for tools/live-sweep; never commit output
//
// Four passes: demo (signed out), a plain tenant, a Partner (client organizations, the "+ Tenant" button, white-label and
// domain entitlements) and a super admin (Platform Console links, HTML Audit, entering a tenant's workspace).
// Covers what the fixture draws. Not covered: error states, the native confirm() prompts, a screen reader.
import { readFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { chromium } from "../../workers/browser-scan/node_modules/playwright-core/index.mjs";
const R = new URL("../..", import.meta.url).pathname.replace(/\/$/, "");
const axeSrc = readFileSync(createRequire(import.meta.url).resolve(`${R}/workers/browser-scan/node_modules/axe-core/axe.min.js`), "utf8");
const ORIGIN = "https://cavscope.28footsystems.com";
const appHtml = readFileSync(`${R}/app.html`, "utf8");

// The page's own fictional sample report (Northstar), read from source so the fixture cannot drift from it.
function sampleSitrep() {
  const start = appHtml.indexOf("const SAMPLE_SITREP = {");
  let i = appHtml.indexOf("{", start), depth = 0, q = null;
  for (let j = i; j < appHtml.length; j++) {
    const c = appHtml[j];
    if (q) { if (c === "\\") j++; else if (c === q) q = null; continue; }
    if (c === "'" || c === '"' || c === "`") { q = c; continue; }
    if (c === "{") depth++; else if (c === "}" && --depth === 0) return new Function(`return ${appHtml.slice(i, j + 1)}`)();
  }
  throw new Error("SAMPLE_SITREP not found in app.html");
}

const now = new Date().toISOString(), later = new Date(Date.now() + 864e5).toISOString();
const sev = (n) => ({ critical: 0, high: 1, medium: 1, low: 1, info: 0, ...n });
const scan = { id: 11, status: "complete", summary: { new: 0, updated: 4, evidence: 18, reopened: 0, resolved: 0, posture_band: "amber", posture_score: 74, open_by_severity: sev({}), skipped_inactive: 0 }, trigger: "scheduled", final_url: "https://site.example.org/", queued_at: now, created_at: now, started_at: now, target_url: "https://site.example.org/", updated_at: now, website_id: 5, finished_at: now, http_status: 200, response_ms: 320, error_message: null, engine_version: "http-native-1.14.0", organization_id: 1, requested_by_id: null, requested_by_agent_id: null };
const brand = { mode: "default", tone: "plain", locale: "en-US", locked: false, eyebrow: "", logo_url: null, is_custom: false, brand_mark: "", brand_name: "", favicon_url: null, accent_color: null, custom_domain: null, primary_color: null, saved_profile: null, report_disclaimer: "", hide_muster_attribution: false };
const flags = Object.fromEntries(["agent_api", "aio_audit", "ai_narrative", "email_alerts", "manual_scans", "multi_website", "risk_register", "board_reporting", "control_mapping", "scheduled_scans", "evidence_library", "remediation_plan", "assurance_testing", "sitrep_generation", "accessibility_audit", "jurisdiction_advisor", "plain_english_report", "governance_exceptions", "promote_finding_to_risk", "html_audit"].map((k) => [k, true]));
const website = { id: 5, url: "https://site.example.org/", name: "site.example.org", created_at: now, environment: "production", latest_scan: scan, posture_band: "amber", latest_sitrep: { id: 21, scan_id: 11, headline: "site.example.org: posture 74/100 (amber)", generated_at: now, posture_band: "amber", posture_score: 74 }, open_findings: 3, posture_score: 74, scan_settings: { enabled: true, max_pages: 25, created_at: now, updated_at: now, website_id: 5, last_run_at: now, next_run_at: later, cadence_minutes: 1440 }, organization_id: 1, open_by_severity: sev({}) };
const finding = (id, rule, severity, category, title) => ({ id, title, detail: `${title}. Detail text for the reader.`, status: "open", risk_id: null, rule_id: rule, category, location: "Homepage", page_url: "https://site.example.org/", severity, confidence: "high", website_id: 5, occurrences: 3, remediation: "Do the fix described here.", resolved_at: null, status_note: null, evidence_ids: [1, 2], last_seen_at: now, first_seen_at: now, plain_english: `In plain words: ${title}.`, framework_refs: { NIST_CSF_V2: "PR.DS-02" } });
const law = (id, short, category, status) => ({ law_id: id, status, assessment: status === "clear" ? "no_open_findings" : "open_findings", category, rule_ids: ["SEC-001"], full_name: `${short} (full name)`, short_name: short, finding_ids: [1], obligations: ["An obligation"], applies_when: "Applies when the organization does a thing.", open_findings: 1, reference_url: "https://example.org/law", jurisdiction_code: "GLOBAL", jurisdiction_rank: 1 });
const sitrep = { id: 21, status: "final", scan_id: 11, version: 1, headline: website.latest_sitrep.headline, sections: sampleSitrep().sections, citations: [], generator: "deterministic-v1", content_md: "# Report\n\nBody.", created_at: now, website_id: 5, generated_at: now, posture_band: "amber", posture_score: 74, content_sha256: "ab".repeat(32), organization_id: 1 };
const overview = { ...website, brand, findings: [finding(1, "SEC-001", "high", "security", "Missing HSTS"), finding(2, "PRIV-001", "medium", "privacy", "No cookie banner"), finding(3, "A11Y-001", "low", "accessibility", "Image without alt text")], compliance: { laws: [law(1, "WCAG 2.2 AA", "accessibility", "evidence_gap"), law(2, "PCI DSS", "security", "clear")], place: "Pennsylvania, US", scanned: true, available: true, disclaimer: "Informational only.", website_id: 5, region_code: "US-PA", country_code: "US", residency_note: "A location-based list is not the list of laws that apply.", location_source: { note: "Taken from the organization record.", basis: null, origin: "organization", source_url: null } }, recent_scans: [scan] };
const org = { id: 1, name: "Example Org", plan: "pro", brand, flags, agents: [], members: [{ name: "Owner", role: "executive", email: "owner@example.org", user_id: 2 }], advisory: { note: null, depth: "summary", law_count: 2, disclaimer: "Informational only.", region_code: "US-PA", country_code: "US", jurisdictions: [{ code: "GLOBAL", kind: "supranational", name: "Global baseline", advisory: "A baseline.", reviewed_at: now }], profile_available: true }, industry: "Technology", timezone: "America/New_York", websites: [website], created_at: now, updated_at: now, plan_detail: { name: "CavScope Pro", plan: "pro", rank: 2, description: "Pro plan", website_limit: 5, scan_cadence_min_minutes: 60 }, region_code: "US-PA", country_code: "US", created_by_id: 2, risk_owner_id: 2, website_limit: 5, commercial_stage: null, is_admin_sandbox: false, managed_by_org_id: null, onboarding_status: "complete", sitrep_recipients: null, critical_alerts_enabled: true, onboarding_completed_at: now, partner_client_allowance: null, sitrep_ready_alerts_enabled: true, role: "executive" };
const risk = { id: 4, title: "Cookie consent banner missing", source: "privacy_assessment", status: "open", category: "privacy", owner_id: 2, severity: "medium", treatment: "mitigate", created_at: now, owner_name: "Owner", updated_at: now, website_id: 5, target_date: later, identified_at: now, inherent_score: 12, residual_score: 12, escalation_context: null, remediation_actions: [{ id: 3, title: "Deploy consent script", status: "not_started", risk_id: 4, due_date: later, owner_id: 2, progress: 0, control_id: null, created_at: now, updated_at: now, description: "Add the consent manager.", verified_at: null, escalated_at: null, status_update: null, escalation_status: null }] };
const appetite = { id: 2, owner_id: 2, statement: "Critical risks are not tolerated in production.", updated_at: now, high_threshold: 2, next_review_at: later, review_cadence: "quarterly", organization_id: 1, critical_threshold: 0 };
let FX = { org, overview, sitrep, risks: [risk], appetite, rules: {} };
let MODE = "demo";
// A Partner: an allowance, the entitlements that come with the tier, and one linked client organization.
const partnerOrg = { ...org, name: "Example Partner", partner_client_allowance: 3, flags: { ...flags, client_management_enabled: true, partner_dashboard_enabled: true, white_label_enabled: true, custom_domain_enabled: true, custom_branding_enabled: true } };
const clientOrg = { ...org, id: 2, name: "Client One", managed_by_org_id: 1, partner_client_allowance: null, websites: [{ ...website, id: 6, organization_id: 2, name: "client.example.com", url: "https://client.example.com/" }] };
const partnerState = { is_partner: true, enabled: true, allowance: 3, clients: [{ id: 2, name: "Client One", industry: "Technology", plan: "pro", websites: 1, posture_score: 74, created_at: now }] };
const local = process.env.FIXTURE && (existsSync(process.env.FIXTURE) ? process.env.FIXTURE : `${R}/${process.env.FIXTURE}`);
if (local) FX = JSON.parse(readFileSync(local, "utf8"));
const handlers = {
  cavscope_claim_invites: () => null, cavscope_onboarding_status: () => ({ next: "workspace", organizations: [{ id: FX.org.id }] }),
  cavscope_my_workspace: () => ({ user: { id: 2, name: "Owner" }, preferences: null, is_super_admin: MODE === "super", platform_flags: {}, organizations: MODE === "partner" ? [partnerOrg, clientOrg] : [FX.org] }),
  cavscope_admin_tenant: (a) => (a.p_organization_id === 2 ? clientOrg : FX.org),
  cavscope_client_orgs: () => (MODE === "partner" ? partnerState : { is_partner: false, enabled: false, allowance: null, clients: [] }),
  cavscope_website_overview: () => FX.overview, cavscope_latest_sitrep: () => FX.sitrep, cavscope_risks: () => FX.risks, cavscope_risk_appetite: () => FX.appetite,
  cavscope_pending_invites: () => [], cavscope_finding_glossary: () => [{ rule_id: "SEC-001", title: "Missing HSTS", severity: "high", category: "security", plain_english: "Meaning.", remediation: "Fix.", checked: true }],
  cavscope_rule_status: (a) => (a.p_rule_ids || []).map((id) => ({ rule_id: id, active: true, title: id, default_severity: "low", engine_floor: null })),
  cavscope_countries: () => [{ code: "US", name: "United States" }], cavscope_regions: () => [{ code: "US-PA", name: "Pennsylvania", country: "US" }],
  cavscope_industries: () => [{ name: "Technology" }, { name: "Healthcare" }], cavscope_llm_config: () => null, cavscope_jurisdiction_advisory: () => FX.org.advisory,
};
const unstubbed = new Set();
const STUB = `window.supabase={createClient:function(){var s=window.__AXE_SIGNED_OUT?null:{user:{email:'owner@example.org',app_metadata:{}},access_token:'x'};
return{auth:{getSession:function(){return Promise.resolve({data:{session:s}})},onAuthStateChange:function(cb){setTimeout(function(){cb('INITIAL_SESSION',s)},0);return{data:{subscription:{unsubscribe:function(){}}}}},signOut:function(){return Promise.resolve({})},signInWithOtp:function(){return Promise.resolve({})},signInWithPassword:function(){return Promise.resolve({error:{message:'stub'}})}},
rpc:function(n,a){return fetch('/__rpc/'+n+'?a='+encodeURIComponent(JSON.stringify(a||{}))).then(function(r){return r.json()})},
from:function(){var q={select:function(){return q},eq:function(){return q},order:function(){return q},limit:function(){return q},then:function(f){return Promise.resolve({data:[],error:null}).then(f)}};return q}}}};`;

const browser = await chromium.launch();
async function pass(label, mode) {
  const signedIn = mode !== "demo";
  MODE = mode;
  const ctx = await browser.newContext({ viewport: { width: 1400, height: 900 } });
  await ctx.route(/^https?:/, async (route) => {
    const u = new URL(route.request().url());
    if (u.origin === ORIGIN) {
      if (u.pathname.startsWith("/__rpc/")) {
        const n = u.pathname.slice(7), h = handlers[n];
        if (!h) { unstubbed.add(n); return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ data: null, error: { message: "unstubbed " + n } }) }); }
        return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ data: h(JSON.parse(u.searchParams.get("a") || "{}")), error: null }) });
      }
      if (u.pathname === "/app") return route.fulfill({ status: 200, contentType: "text/html", body: appHtml.replace(/(supabase\.min\.js")\s+integrity="[^"]*"/, "$1") });
      const f = `${R}${u.pathname}`;
      return existsSync(f) ? route.fulfill({ status: 200, body: readFileSync(f) }) : route.fulfill({ status: 404, body: "not found" });
    }
    if (/supabase\.min\.js/.test(u.pathname)) return route.fulfill({ status: 200, contentType: "text/javascript", body: STUB });
    if (/supabase\.co/.test(u.host)) return route.abort("blockedbyclient");
    try { const res = await fetch(u.toString()); return route.fulfill({ status: res.status, contentType: res.headers.get("content-type") ?? "text/plain", body: Buffer.from(await res.arrayBuffer()) }); } catch { return route.abort("failed"); }
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e.message).slice(0, 200)));
  if (!signedIn) await page.addInitScript("window.__AXE_SIGNED_OUT = true");
  // A super admin arriving with no fragment is sent to /admin once; #overview is what the console's own link uses.
  await page.goto(`${ORIGIN}/app${mode === "super" ? "#overview" : ""}`, { waitUntil: "networkidle" });
  await page.waitForTimeout(1200);
  await page.evaluate(axeSrc);
  const live = await page.evaluate(() => typeof Live !== "undefined" && !!Live.session);
  if (signedIn && !live) console.log(`[${label}] WARNING: not signed in after boot; the signed-in pass is not what it claims`);
  // A modal left open by boot (sign-in prompt, welcome) hides the views from axe's point of view; report it.
  const views = await page.evaluate(() => [...document.querySelectorAll("section.view")].map((s) => s.id));
  let bad = 0;
  for (const v of views) {
    const before = errors.length;
    await page.evaluate((id) => showView(id), v);
    await page.mouse.move(700, 890); await page.keyboard.press("Escape"); await page.waitForTimeout(200);
    const res = await page.evaluate(async () => (await axe.run({ exclude: [["#appTooltip"]] }, { resultTypes: ["violations"] })).violations.map((x) => ({ id: x.id, impact: x.impact, n: x.nodes.length, help: x.help, nodes: x.nodes.slice(0, 3).map((n) => `${n.target.join(" ")} :: ${n.html.slice(0, 120).replace(/\s+/g, " ")} :: ${n.failureSummary.replace(/\s+/g, " ").slice(0, 170)}`) })));
    const text = await page.evaluate((id) => document.getElementById(id).innerText.length, v);
    const errs = errors.slice(before);
    if (res.length || errs.length) bad++;
    console.log(`${label.padEnd(5)} ${v.padEnd(22)} [${String(text).padStart(5)} chars] ${res.length ? res.map((x) => `${x.id}(${x.n},${x.impact})`).join(" ") : "no violations"}${errs.length ? "  SCRIPT ERROR: " + errs.join(" | ") : ""}`);
    if (process.env.DETAIL) for (const x of res) { console.log(`   ## ${x.help}`); x.nodes.forEach((n) => console.log("     ", n)); }
  }
  if (!views.length) { console.log(`[${label}] no views found`, errors.join(" | ")); bad++; }

  // What each session is entitled to see, and not to see. Hiding is presentation (the RPCs enforce), but a link shown
  // to the wrong person, or hidden from the right one, is a defect this pass can see.
  if (signedIn) {
    const vis = await page.evaluate(() => { const v = (id) => { const e = document.getElementById(id); return !!e && !e.hidden && !!(e.offsetWidth || e.offsetHeight); }; return { tenantBtn: v("btnCreateTenant"), console: v("navPlatformConsole"), consoleBtn: v("btnPlatformConsole"), htmlAudit: v("navHtmlAudit") }; });
    const want = { tenant: { tenantBtn: false, console: false, consoleBtn: false, htmlAudit: true }, partner: { tenantBtn: true, console: false, consoleBtn: false, htmlAudit: true }, super: { tenantBtn: false, console: true, consoleBtn: true, htmlAudit: true } }[mode];
    const wrong = Object.keys(want).filter((k) => vis[k] !== want[k] && !(k === "htmlAudit" && mode === "tenant"));
    if (wrong.length) { bad++; console.log(`${label.padEnd(5)} ENTITLEMENT: ${wrong.map((k) => `${k} is ${vis[k] ? "shown" : "hidden"}, expected ${want[k] ? "shown" : "hidden"}`).join("; ")}`); }
    else console.log(`${label.padEnd(5)} entitlements as expected (${Object.entries(vis).map(([k, v]) => `${k}:${v ? "shown" : "hidden"}`).join(" ")})`);
  }
  if (mode === "partner") {
    // The fixture must actually reach the page: the tenant switcher lists the client organization.
    const opts = await page.evaluate(() => [...document.querySelectorAll("#topbarTenantSelect option")].map((o) => o.textContent.trim()));
    const ok = opts.some((t) => /Client One/.test(t));
    if (!ok) bad++;
    console.log(`${label.padEnd(5)} tenant switcher lists: ${opts.join(" | ") || "(nothing)"}${ok ? "" : "  CLIENT ORG MISSING"}`);
  }
  if (mode === "super") {
    // Entering a tenant's workspace as a super admin renders that tenant's data under the super admin's session.
    await page.evaluate(() => Live.openTenant(2)).catch((e) => errors.push(`openTenant: ${String(e.message).slice(0, 120)}`));
    await page.waitForTimeout(500);
    for (const v of ["overview", "teamSettings", "subclients"]) {
      await page.evaluate((id) => showView(id), v); await page.mouse.move(700, 890); await page.waitForTimeout(200);
      const res = await page.evaluate(async () => (await axe.run({ exclude: [["#appTooltip"]] }, { resultTypes: ["violations"] })).violations.map((x) => `${x.id}(${x.nodes.length},${x.impact})`));
      if (res.length) bad++;
      console.log(`${label.padEnd(5)} ${("entered:" + v).padEnd(22)} ${res.length ? res.join(" ") : "no violations"}`);
    }
    await page.evaluate(() => Live.openTenant(1)).catch(() => {});
    await page.waitForTimeout(300);
  }

  // Modals. axe sees only what is on screen, so each one is opened, scanned, then checked for the things axe
  // cannot: a dialog role and name, focus moved inside, and Escape closing it.
  await page.evaluate(() => showView("overview"));
  const MODALS = [
    // A live workspace refuses the record forms that save nothing (DEMO_ONLY_MODALS) and hides "+ Tenant", so only demo opens those.
    ...["risk", "control", "evidence", "remediation", "appetite", "exception", "objective", "test", "add_subclient", "create_client_org", "create_tenant", "whitelabel_settings"].filter((t) => !signedIn || !["risk", "control", "evidence", "exception", "remediation", "test", "objective", "create_tenant"].includes(t)).map((t) => ({ name: `modal:${t}`, backdrop: "#modalBackdrop", open: `openModal(${JSON.stringify(t)})`, close: "closeModal()" })),
    ...["posture", "controls", "evidence", "remediation"].map((k) => ({ name: `explainer:${k}`, backdrop: "#scoreExplainerBackdrop", open: `openScoreExplainer(${JSON.stringify(k)})`, close: "closeScoreExplainer()" })),
    ...(signedIn ? [{ name: "onboarding", backdrop: "#liveOnboardBackdrop", open: "Live.openOnboard()", close: 'document.getElementById("liveOnboardBackdrop").classList.remove("open")' }, { name: "support panel", backdrop: "#csSupportPanel", open: 'document.getElementById("csSupportTab").click()', close: 'document.getElementById("csSupportTab").click()', panel: true }]
      : [{ name: "sign-in", backdrop: "#liveAuthBackdrop", open: "Live.openAuth()", close: "Live.closeAuth()" }]),
  ];
  if (mode === "partner") MODALS.push({ name: "+ Tenant (partner)", backdrop: "#modalBackdrop", open: "Live.beginClientOrg()", close: "closeModal()" });
  for (const m of MODALS) {
    const before = errors.length;
    await page.evaluate(m.open).catch((e) => errors.push(`open ${m.name}: ${String(e.message).slice(0, 120)}`));
    if (m.panel) await page.waitForFunction(() => !document.getElementById('csSupportPanel').hidden, null, { timeout: 8000 }).catch(() => {});
    await page.waitForTimeout(250);
    const info = await page.evaluate(({ sel, panel }) => {
      const root = document.querySelector(sel);
      const shown = !!root && (panel ? !root.hidden : root.classList.contains("open"));
      const dlg = panel ? root : root?.querySelector(".modal-dialog");
      const role = dlg?.getAttribute("role") || root?.getAttribute("role");
      const modal = dlg?.getAttribute("aria-modal") || root?.getAttribute("aria-modal");
      const named = !!(dlg?.getAttribute("aria-labelledby") || dlg?.getAttribute("aria-label") || root?.getAttribute("aria-labelledby") || root?.getAttribute("aria-label"));
      const inside = !!dlg && dlg.contains(document.activeElement);
      return { shown, dialog: role === "dialog" || role === "alertdialog", modal: modal === "true", named, inside };
    }, { sel: m.backdrop, panel: !!m.panel });
    if (!info.shown) { console.log(`${label.padEnd(5)} ${m.name.padEnd(22)} did not open${errors.length > before ? "  " + errors.slice(before).join(" | ") : ""}`); bad++; continue; }
    const res = await page.evaluate(async () => (await axe.run({ exclude: [["#appTooltip"]] }, { resultTypes: ["violations"] })).violations.map((x) => ({ id: x.id, impact: x.impact, n: x.nodes.length, help: x.help, nodes: x.nodes.slice(0, 3).map((n) => `${n.target.join(" ")} :: ${n.html.slice(0, 110).replace(/\s+/g, " ")} :: ${n.failureSummary.replace(/\s+/g, " ").slice(0, 150)}`) })));
    await page.keyboard.press("Escape"); await page.waitForTimeout(150);
    const closedByEsc = await page.evaluate(({ sel, panel }) => { const r = document.querySelector(sel); return panel ? r.hidden : !r.classList.contains("open"); }, { sel: m.backdrop, panel: !!m.panel });
    if (!closedByEsc) await page.evaluate(m.close).catch(() => {});
    const gaps = [!info.dialog && "no dialog role", !info.modal && !m.panel && "no aria-modal", !info.named && "no accessible name", !info.inside && "focus stays outside", !closedByEsc && "Escape does not close"].filter(Boolean);
    if (res.length || gaps.length) bad++;
    console.log(`${label.padEnd(5)} ${m.name.padEnd(22)} ${res.length ? res.map((x) => `${x.id}(${x.n},${x.impact})`).join(" ") : "axe clean"}${gaps.length ? "  | " + gaps.join(", ") : ""}${errors.length > before ? "  SCRIPT ERROR: " + errors.slice(before).join(" | ") : ""}`);
    if (process.env.DETAIL) for (const x of res) { console.log(`   ## ${x.help}`); x.nodes.forEach((n) => console.log("     ", n)); }
  }
  await ctx.close();
  return bad;
}
let bad = await pass("demo", "demo");
bad += await pass("live", "tenant");
bad += await pass("part", "partner");
bad += await pass("super", "super");

// A super admin who arrives with no fragment is sent to the console, once. Check it, and that nobody else is.
for (const [mode, expectConsole] of [["super", true], ["tenant", false]]) {
  MODE = mode;
  const ctx = await browser.newContext();
  await ctx.route(/^https?:/, async (route) => {
    const u = new URL(route.request().url());
    if (u.origin === ORIGIN && u.pathname.startsWith("/__rpc/")) { const h = handlers[u.pathname.slice(7)]; return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ data: h ? h(JSON.parse(u.searchParams.get("a") || "{}")) : null, error: h ? null : { message: "unstubbed" } }) }); }
    if (u.origin === ORIGIN && u.pathname === "/app") return route.fulfill({ status: 200, contentType: "text/html", body: appHtml.replace(/(supabase\.min\.js")\s+integrity="[^"]*"/, "$1") });
    if (u.origin === ORIGIN) return route.fulfill({ status: 200, contentType: "text/html", body: "<title>console</title>" });
    if (/supabase\.min\.js/.test(u.pathname)) return route.fulfill({ status: 200, contentType: "text/javascript", body: STUB });
    return route.abort("blockedbyclient");
  });
  const page = await ctx.newPage();
  await page.goto(`${ORIGIN}/app`).catch(() => {});
  await page.waitForTimeout(1500);
  const went = new URL(page.url()).pathname === "/admin";
  if (went !== expectConsole) bad++;
  console.log(`${mode.padEnd(5)} /app with no fragment ${went ? "goes to /admin" : "stays in the workspace"}${went === expectConsole ? "" : "  UNEXPECTED"}`);
  await ctx.close();
}
if (unstubbed.size) console.log(`\nRPCs the page called that the fixture does not stub (they answered an error): ${[...unstubbed].join(", ")}`);
await browser.close();
process.exit(bad ? 1 : 0);
