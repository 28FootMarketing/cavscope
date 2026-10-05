// The only module that drives a browser. It collects raw observations for one page; every judgement
// about them lives in rules.mjs. Keeping the two apart is what lets the rules be tested without Chromium.
//
// CSP: the page is never given bypassCSP. axe-core is injected through the DevTools protocol
// (page.evaluate), which a Content-Security-Policy does not govern, so the page's own policy stays
// in force for everything the page itself does. The inline-script probe for SEC-022 deliberately
// goes through the DOM (a <script> element), because that IS the path a policy governs.

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { chromium } from "playwright-core";
import { resolveTextContrast } from "./contrast.mjs";

const require = createRequire(import.meta.url);
export const AXE_VERSION = require("axe-core/package.json").version;
const AXE_SOURCE = readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
export const AXE_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa", "best-practice"];
export const AXE_INJECTION = "devtools_evaluate (page CSP unchanged)";

export const NAV_TIMEOUT_MS = 30_000;
export const NAV_RETRIES = 2;

// BROWSER_PROXY is for hosts whose only route out is an egress proxy. TLS errors are never ignored here;
// a caller that must (a sandbox with an intercepting proxy) passes contextOptions, and the worker does not.
export async function launchBrowser() {
  return chromium.launch({
    headless: true, executablePath: process.env.CHROMIUM_PATH || undefined,
    proxy: process.env.BROWSER_PROXY ? { server: process.env.BROWSER_PROXY } : undefined,
  });
}

// One fresh context per scan: no cookies, storage or cache carried from any earlier scan.
export async function newScanContext(browser, { userAgent, contextOptions = {} } = {}) {
  return browser.newContext({
    userAgent: userAgent ?? "Mozilla/5.0 (compatible; CavScope-Browser/1.0; +https://cavscope.28footsystems.com)",
    viewport: { width: 1280, height: 900 },
    ignoreHTTPSErrors: false,
    bypassCSP: false,
    serviceWorkers: "block",
    ...contextOptions,
  });
}

const withCacheBust = (url, on) => {
  if (!on) return url;
  const u = new URL(url);
  u.searchParams.set("cavscope_cb", Date.now().toString(36) + Math.random().toString(36).slice(2, 6));
  return u.toString();
};

async function gotoWithRetry(page, url, reset) {
  let lastErr = null;
  for (let attempt = 0; attempt <= NAV_RETRIES; attempt++) {
    // Requests and console output from an attempt that failed belong to that attempt, not to the site.
    reset();
    try {
      const t0 = Date.now();
      const res = await page.goto(url, { waitUntil: "networkidle", timeout: NAV_TIMEOUT_MS });
      return { res, ms: Date.now() - t0, attempts: attempt + 1 };
    } catch (e) {
      lastErr = e;
      if (attempt < NAV_RETRIES) await new Promise((r) => setTimeout(r, 750 * (attempt + 1)));
    }
  }
  const err = new Error(String(lastErr?.message ?? lastErr).split("\n")[0]);
  err.attempts = NAV_RETRIES + 1;
  throw err;
}

// Runs in the page. Returns plain data only.
function pageProbe() {
  const text = (el) => (el.innerText || el.textContent || "").replace(/\s+/g, " ").trim();
  const imgs = [...document.images];
  const structure = {
    title: document.title,
    h1Count: document.querySelectorAll("h1").length,
    lang: document.documentElement.getAttribute("lang"),
    imgTotal: imgs.length,
    imgNoAlt: imgs.filter((i) => !i.hasAttribute("alt")).length,
  };
  const labelFor = (el) => {
    if (el.labels && el.labels.length) return [...el.labels].map(text).join(" ");
    const wrap = el.closest("label");
    if (wrap) return text(wrap);
    return el.getAttribute("aria-label") || "";
  };
  const forms = [...document.forms].map((f) => {
    const fields = [...f.elements].filter((e) => e.name || e.id).map((e) => ({
      name: e.name || "", id: e.id || "", type: (e.type || e.tagName || "").toLowerCase(),
      required: !!e.required, checked: !!e.checked, autocomplete: e.getAttribute("autocomplete") || "",
      label: labelFor(e).slice(0, 600),
      hidden: e.type === "hidden" || e.offsetParent === null && e.type !== "checkbox" && e.type !== "radio",
    }));
    // Nearby text: the form itself plus the container a short way up, which is where consent copy lives.
    let scope = f;
    for (let i = 0; i < 2 && scope.parentElement && text(scope).length < 120; i++) scope = scope.parentElement;
    const links = [...scope.querySelectorAll("a[href]")].map((a) => ({ text: text(a).slice(0, 120), href: a.href })).slice(0, 30);
    const nearText = text(scope).slice(0, 2500);
    return {
      id: f.id || "", name: f.getAttribute("name") || "",
      rawAction: f.getAttribute("action"), action: f.action, method: (f.method || "get").toLowerCase(),
      fields, links, nearText,
      hasPassword: fields.some((x) => x.type === "password"),
      hasPayment: fields.some((x) => /^cc-|card|cvc|cvv/i.test(`${x.autocomplete} ${x.name} ${x.id}`)),
    };
  });
  const links = [...document.querySelectorAll("a[href]")].map((a) => a.href).slice(0, 400);
  return { structure, forms, links, textSample: text(document.body).slice(0, 6000) };
}

// Runs in the page. For each selector, the foreground colour, size, and the stack of backgrounds up
// the ancestor chain, nearest first, stopping at the first opaque colour with no image.
function contrastProbe(selectors) {
  const out = [];
  for (const sel of selectors) {
    let el = null;
    try { el = document.querySelector(sel); } catch { /* selector from a shadow root or iframe */ }
    if (!el) { out.push({ selector: sel, missing: true }); continue; }
    const cs = getComputedStyle(el);
    // Text painted by its own gradient (background-clip: text) has no separate background: the gradient IS
    // the ink. Reading it as a backdrop gives white on white. It cannot be settled from colours, so say so.
    if (cs.backgroundClip === "text" || cs.webkitBackgroundClip === "text") { out.push({ selector: sel, clippedText: true }); continue; }
    const backgrounds = [];
    let opacity = 1;
    for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
      const s = getComputedStyle(node);
      opacity *= parseFloat(s.opacity);
      if (s.backgroundImage && s.backgroundImage !== "none") {
        backgrounds.push({ kind: /gradient\(/.test(s.backgroundImage) && !/url\(/.test(s.backgroundImage) ? "gradient" : "image", value: s.backgroundImage });
      }
      const bg = s.backgroundColor;
      const m = /rgba?\(([^)]+)\)/.exec(bg);
      const alpha = m ? (m[1].split(/[\s,/]+/)[3] === undefined ? 1 : parseFloat(m[1].split(/[\s,/]+/)[3])) : 0;
      if (alpha > 0) {
        backgrounds.push({ kind: "color", value: bg });
        if (alpha >= 1 && !(s.backgroundImage && s.backgroundImage !== "none")) break;
      }
    }
    out.push({
      selector: sel, color: cs.color, fontSizePx: parseFloat(cs.fontSize), fontWeight: cs.fontWeight,
      effectiveOpacity: opacity, backgrounds,
    });
  }
  return out;
}

// For a form with no usable action, find out where a script would send it WITHOUT sending anything:
// every request is aborted in the browser before it leaves, and only its destination is recorded.
// Fields get obvious test values; nothing reaches the site. (The active-test rules, FORM-010 and
// FORM-011, are the ones that send data, and they need an authorization record.)
export const TEST_NAME = "CAVSCOPE TEST (delete me)";
export const TEST_EMAIL = "cavscope-test@example.com";
export async function observeFormSubmission(page, formIndex) {
  const seen = [];
  let hiddenFields = [];
  await page.route("**/*", (route) => {
    const r = route.request();
    seen.push({ url: r.url(), method: r.method(), type: r.resourceType(), isNav: r.isNavigationRequest(),
      contentType: r.headers()["content-type"] ?? null, body: (r.postData() ?? "").slice(0, 4000) });
    return route.abort("blockedbyclient");
  });
  try {
    const filled = await page.evaluate(([i, name, email, phone]) => {
      const f = document.forms[i];
      const hidden = [];
      if (!f) return { hidden };
      for (const el of f.elements) {
        const t = (el.type || "").toLowerCase();
        if (el.disabled || t === "hidden" || t === "submit" || t === "button") continue;
        const visible = el.offsetParent !== null || t === "checkbox" || t === "radio";
        if (!visible) { if (el.name && ["text", "email", "url", "tel", "textarea", "search"].includes(t || el.tagName.toLowerCase())) hidden.push(el.name); continue; }
        if (t === "email") el.value = email;
        else if (t === "tel") el.value = phone;
        else if (t === "checkbox") el.checked = !!el.required;
        else if (t === "radio") { if (el.required) el.checked = true; }
        else if (el.tagName === "SELECT") { const o = [...el.options].find((x) => x.value); if (o) el.value = o.value; }
        else if (t === "number") el.value = "1";
        else if (t === "url") el.value = "https://example.com";
        else if (t === "password" || t === "file") continue;
        else el.value = name;
        el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true }));
      }
      return { hidden };
    }, [formIndex, TEST_NAME, TEST_EMAIL, "5555550100"]);
    hiddenFields = filled?.hidden ?? [];
    await page.waitForTimeout(3300); // forms commonly ignore a submit that comes too fast
    await page.evaluate((i) => { const f = document.forms[i]; if (f) f.requestSubmit(); }, formIndex);
    await page.waitForTimeout(1500);
  } catch { /* a handler that throws is itself an observation: nothing was seen */ }
  finally { await page.unroute("**/*").catch(() => {}); }
  const out = seen.filter((x) => /^https?:/i.test(x.url) && (x.method !== "GET" || !x.isNav));
  // The body holds only the obvious test values filled in above; the active tests reuse its shape.
  return { requests: out.map(({ url, method, contentType, body }) => ({ url: url.slice(0, 300), method, contentType, body })), blocked: true, hiddenFields };
}

const trimNodes = (items) => (items ?? []).map((v) => ({
  id: v.id, impact: v.impact ?? null, help: v.help, helpUrl: v.helpUrl,
  nodes: (v.nodes ?? []).slice(0, 25).map((n) => ({
    target: n.target?.map(String), html: String(n.html ?? "").slice(0, 300),
    failureSummary: String(n.failureSummary ?? "").slice(0, 300),
    message: String(n.any?.[0]?.message ?? n.all?.[0]?.message ?? n.none?.[0]?.message ?? "").slice(0, 200),
  })),
  nodeCount: (v.nodes ?? []).length,
}));

// Collects one page. `opts.first` also reads the cookie jar before anything else happens and runs the
// CSP probe last. Never throws: a page that cannot load comes back with `error`.
export async function collectPage(context, url, { cacheBust = false, first = false, evidenceKey, runAxe = true, observeForms = true } = {}) {
  const page = await context.newPage();
  const requests = [];
  const consoleLog = [];
  const byReq = new Map();
  let recording = true;
  page.on("request", (r) => {
    if (!recording) return;
    let host = "";
    try { host = new URL(r.url()).hostname; } catch { /* data: and blob: have no host */ }
    const rec = { url: r.url(), host, resourceType: r.resourceType(), status: null, failed: false, aborted: false, failureText: null };
    byReq.set(r, rec);
    if (/^https?:/i.test(r.url())) requests.push(rec);
  });
  page.on("response", (res) => { const rec = byReq.get(res.request()); if (rec) rec.status = res.status(); });
  page.on("requestfailed", (r) => {
    if (!recording) return;
    const rec = byReq.get(r);
    if (!rec) return;
    rec.failed = true; rec.failureText = r.failure()?.errorText ?? "failed";
    rec.aborted = /ERR_ABORTED/i.test(rec.failureText);
  });
  // The SEC-022 probe deliberately triggers a policy refusal. Its console message is ours, not the
  // site's, so it is not recorded: otherwise SEC-021 would report the scanner's own test as a site fault.
  let probing = false;
  page.on("console", (m) => { if (recording && !probing) consoleLog.push({ type: m.type(), text: m.text().slice(0, 500) }); });

  const out = { url, evidenceKey, requests, console: consoleLog };
  try {
    const target = withCacheBust(url, cacheBust);
    const nav = await gotoWithRetry(page, target, () => { requests.length = 0; consoleLog.length = 0; byReq.clear(); });
    out.finalUrl = page.url().replace(/([?&])cavscope_cb=[^&]*&?/, "$1").replace(/[?&]$/, "");
    out.status = nav.res?.status() ?? null;
    out.ms = nav.ms; out.attempts = nav.attempts; out.cacheBust = cacheBust;
    out.contentType = nav.res?.headers()["content-type"] ?? null;

    if (first) {
      out.cookies = (await context.cookies()).map((c) => ({
        name: c.name, domain: c.domain, path: c.path, secure: c.secure, httpOnly: c.httpOnly, sameSite: c.sameSite,
        expires: c.expires > 0 ? new Date(c.expires * 1000).toISOString() : "session",
      }));
    }

    const probe = await page.evaluate(pageProbe);
    out.structure = probe.structure; out.forms = probe.forms; out.links = probe.links; out.textSample = probe.textSample;

    if (runAxe) {
      await page.evaluate(AXE_SOURCE);
      const axeRes = await page.evaluate(
        (tags) => window.axe.run(document, { runOnly: { type: "tag", values: tags }, resultTypes: ["violations", "incomplete"] }),
        AXE_TAGS,
      );
      out.axe = { version: AXE_VERSION, tags: AXE_TAGS, injection: AXE_INJECTION, violations: trimNodes(axeRes.violations), incomplete: trimNodes(axeRes.incomplete), passes: axeRes.passes?.length ?? null };

      // Settle the contrast cases axe could not, from computed colours.
      const cc = axeRes.incomplete.find((i) => i.id === "color-contrast");
      out.contrast = [];
      if (cc) {
        const sels = cc.nodes.map((n) => n.target?.[0]).filter((s) => typeof s === "string").slice(0, 60);
        const probes = await page.evaluate(contrastProbe, sels);
        for (const pr of probes) {
          if (pr.clippedText) { out.contrast.push({ target: pr.selector, status: "unresolved", reason: "text is painted by a gradient (background-clip: text)", ratio: null }); continue; }
          if (pr.missing) { out.contrast.push({ target: pr.selector, status: "unresolved", reason: "element is inside a shadow root or frame", ratio: null }); continue; }
          if (pr.effectiveOpacity < 0.999) { out.contrast.push({ target: pr.selector, status: "unresolved", reason: "element or an ancestor is partially transparent", ratio: null }); continue; }
          const r = resolveTextContrast({ color: pr.color, backgrounds: pr.backgrounds, fontSizePx: pr.fontSizePx, fontWeight: pr.fontWeight });
          out.contrast.push({ target: pr.selector, ...r });
        }
      }
    }

    recording = false; // everything after this point is the scanner's own doing, not the site's
    if (first) {
      // Last, because it adds a node to the page. Goes through the DOM so the page's CSP governs it.
      probing = true;
      out.cspProbe = await page.evaluate(() => new Promise((resolve) => {
        let violated = false;
        document.addEventListener("securitypolicyviolation", () => { violated = true; }, { once: true });
        const s = document.createElement("script");
        s.textContent = "window.__cavscopeCspProbe = 1";
        document.head.appendChild(s);
        setTimeout(() => resolve({ executed: window.__cavscopeCspProbe === 1, violationEvent: violated }), 150);
      }));
      probing = false;
    }
    // Last of all, because it fills the form in. Only forms with no usable action need it.
    if (observeForms) {
      for (const [i, f] of (out.forms ?? []).entries()) {
        if (i >= 3) break;
        const raw = f.rawAction;
        if (raw == null || raw.trim() === "" || raw.trim() === "#" || /^javascript:/i.test(raw.trim())) f.observed = await observeFormSubmission(page, i);
      }
    }
  } catch (e) {
    out.error = String(e?.message ?? e).slice(0, 300);
    out.attempts = e?.attempts ?? 1;
  } finally {
    await page.close().catch(() => {});
  }
  return out;
}


// FORM-011. Network OPEN: this really submits the form. Only called by the engine after
// activeTestsPermitted() said yes. One form, once. Waits the minimum fill time first.
export async function liveSubmit(context, pageUrl, formIndex) {
  const page = await context.newPage();
  const responses = [];
  page.on("response", (res) => { const r = res.request(); if (r.method() !== "GET" && /^https?:/i.test(r.url())) responses.push({ url: r.url().slice(0, 300), method: r.method(), status: res.status() }); });
  const out = { pageUrl, responses, success: false };
  try {
    await page.goto(pageUrl, { waitUntil: "networkidle", timeout: NAV_TIMEOUT_MS });
    const before = await page.evaluate(() => document.body.innerText);
    await page.evaluate(([i, name, email, phone]) => {
      const f = document.forms[i];
      for (const el of f.elements) {
        const t = (el.type || "").toLowerCase();
        if (el.disabled || t === "hidden" || t === "submit" || t === "button" || t === "password" || t === "file") continue;
        const visible = el.offsetParent !== null || t === "checkbox" || t === "radio";
        if (!visible) continue;
        if (t === "email") el.value = email; else if (t === "tel") el.value = phone;
        else if (t === "checkbox") el.checked = !!el.required; else if (t === "radio") { if (el.required) el.checked = true; }
        else if (el.tagName === "SELECT") { const o = [...el.options].find((x) => x.value); if (o) el.value = o.value; }
        else if (t === "number") el.value = "1"; else if (t === "url") el.value = "https://example.com";
        else el.value = name;
        el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true }));
      }
    }, [formIndex, TEST_NAME, TEST_EMAIL, "5555550100"]);
    await page.waitForTimeout(3300);
    await page.evaluate((i) => document.forms[i].requestSubmit(), formIndex);
    await page.waitForTimeout(3000);
    out.success = await page.evaluate((beforeText) => {
      const after = document.body.innerText;
      const re = /thank|success|received|message (was )?sent|we.ll be in touch|we will be in touch|submitted/i;
      const live = [...document.querySelectorAll("[role=status],[role=alert],[aria-live]")].some((e) => re.test(e.innerText || ""));
      return live || (re.test(after) && !re.test(beforeText)) || /thank|success|confirm/i.test(location.pathname);
    }, before);
  } catch (e) { out.error = String(e?.message ?? e).slice(0, 200); }
  finally { await page.close().catch(() => {}); }
  return out;
}
