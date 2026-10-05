// The scan itself: discover pages, collect each in a browser, evaluate the rules, build evidence.
// I/O is injected (`deps`) so the same function runs against a real site, a local fixture server, or
// a test double.

import { createHash } from "node:crypto";
import { resolve4, resolveNs } from "node:dns/promises";
import { AXE_VERSION, collectPage, launchBrowser, liveSubmit, newScanContext } from "./collect.mjs";
import { activeTestsPermitted, buildMatrix, evaluateLiveSubmit, evaluateMatrix, runMatrix } from "./active.mjs";
import { MAX_PAGES, normalizeUrl, parseRobots, parseSitemap, sameOrigin, selectPages } from "./discover.mjs";
import { confirmFailedRequests } from "./confirm.mjs";
import { waitForDeploy } from "./deploy-wait.mjs";
import { dnsProvider, isFirstParty, registrableDomain } from "./hosts.mjs";
import {
  evaluateAxe, evaluateCookies, evaluateCspConsole, evaluateCspProbe, evaluateForms001, evaluateMinors,
  evaluateSmsConsent, evaluateStructure, evaluateThirdParties,
} from "./rules.mjs";

export const ENGINE_VERSION = "browser-1.0.0";
const EXCERPT = 8000;

export const sha256Hex = (text) => createHash("sha256").update(text).digest("hex");

// Hashed the way the HTTP engine hashes: sha-256 hex of the raw captured text. The stored excerpt is cut
// to what the database keeps; the hash covers the whole thing.
export function evidenceRow({ key, kind, url, status = null, contentType = "application/json", ms = null, raw, headers = null }) {
  const body = typeof raw === "string" ? raw : JSON.stringify(raw, null, 2);
  return { key, kind, url, http_status: status, content_type: contentType, response_ms: ms, headers, excerpt: body.slice(0, EXCERPT), byte_length: body.length, sha256: sha256Hex(body) };
}

const realFetch = async (url, init = {}) => {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 10_000);
  try { return await fetch(url, { redirect: "follow", signal: ctl.signal, headers: { "user-agent": "CavScope-Browser/1.0" }, ...init }); }
  finally { clearTimeout(t); }
};

export const defaultDeps = {
  fetchText: async (url) => { try { const r = await realFetch(url); return { status: r.status, text: r.ok ? await r.text() : "" }; } catch { return { status: 0, text: "" }; } },
  fetchStatus: async (url) => { try { return (await realFetch(url)).status; } catch { return null; } },
  resolveNs: async (host) => { try { return await resolveNs(host); } catch { return []; } },
};

async function discoverPages({ home, deps, cap }) {
  const origin = new URL(home).origin;
  const robotsRes = await deps.fetchText(`${origin}/robots.txt`);
  const robots = parseRobots(robotsRes.status === 200 ? robotsRes.text : "");
  const sitemapUrls = [];
  const declared = [...(robotsRes.text || "").matchAll(/^\s*sitemap:\s*(\S+)/gim)].map((m) => m[1]);
  const smCandidates = declared.length ? declared : [`${origin}/sitemap.xml`];
  for (const sm of smCandidates.slice(0, 3)) {
    const r = await deps.fetchText(sm);
    if (r.status !== 200) continue;
    const parsed = parseSitemap(r.text);
    if (parsed.kind === "urlset") sitemapUrls.push(...parsed.locs);
    else for (const child of parsed.locs.slice(0, 3)) {
      const cr = await deps.fetchText(child);
      if (cr.status === 200) sitemapUrls.push(...parseSitemap(cr.text).locs);
    }
  }
  return { robots, sitemapUrls, robotsStatus: robotsRes.status };
}

// Runs one full pass. Returns everything the rules and the report need.
async function pass({ targetUrl, options, deps, browser, cap, contextOptions }) {
  const cacheBust = !!options.cache_bust;
  const context = await newScanContext(browser, { contextOptions });
  // A caller-supplied hook (tests, and sandboxes with an intercepting proxy). The worker passes none.
  if (deps.configureContext) await deps.configureContext(context);
  const pages = [];
  try {
    const first = await collectPage(context, targetUrl, { cacheBust, first: true, evidenceKey: "page_1" });
    pages.push(first);
    const finalHome = first.finalUrl || targetUrl;
    const origin = new URL(finalHome).origin;
    const { robots, sitemapUrls, robotsStatus } = await discoverPages({ home: finalHome, deps, cap });

    // A sitemap may list the other www / non-www spelling of the host the site redirected to.
    const bare = (h) => h.replace(/^www\./, "");
    const remap = (u) => { try { const x = new URL(u); if (bare(x.hostname) === bare(new URL(origin).hostname)) { x.protocol = new URL(origin).protocol; x.host = new URL(origin).host; return x.toString(); } } catch { /* leave it */ } return u; };
    const fromLinks = (first.links ?? []).filter((l) => sameOrigin(l, origin));
    const candidates = (sitemapUrls.length ? sitemapUrls.map(remap) : fromLinks);
    const { pages: urls, skippedByRobots } = selectPages({ origin, home: finalHome, candidates, robots, cap });

    // The first page is already collected; keep its place and visit the rest.
    for (const [i, u] of urls.entries()) {
      if (normalizeUrl(u) === normalizeUrl(finalHome)) continue;
      pages.push(await collectPage(context, u, { cacheBust, evidenceKey: `page_${pages.length + 1}` }));
    }
    return { pages, origin, discovery: { robotsStatus, robotsRules: robots.ruleCount, usedSitemap: sitemapUrls.length > 0, sitemapUrlCount: sitemapUrls.length, skippedByRobots, cap } };
  } finally {
    await context.close().catch(() => {});
  }
}

export function evaluateAll({ pages, origin, siteHost, fetchStatus }) {
  const loaded = pages.filter((p) => !p.error);
  // A page that lost some of its own files while loading may lay out differently from what a visitor sees,
  // and layout-dependent axe rules (target size, contrast, overlap) can then be wrong in either direction.
  for (const p of loaded) p.degraded = (p.requests ?? []).some((r) => r.failed && !r.aborted && !r.transient && r.host && isFirstParty(r.host, siteHost));
  const first = pages[0];
  const results = [
    evaluateAxe({ pages: loaded, origin, axeVersion: AXE_VERSION }),
    evaluateStructure({ pages: loaded, origin }),
    evaluateThirdParties({ pages: loaded, siteHost, origin }),
    evaluateCookies({ firstLoad: first && !first.error ? { cookies: first.cookies, requests: first.requests } : null, siteHost, origin }),
    evaluateCspConsole({ pages: loaded, siteHost, origin }),
    evaluateCspProbe({ probe: first && !first.error && first.cspProbe ? { ...first.cspProbe, page: new URL(first.finalUrl || first.url).pathname || "/" } : null, origin }),
    evaluateForms001({ pages: loaded, origin }),
    evaluateMinors({ pages: loaded, origin }),
  ];
  return { results, loaded };
}

// `deps.previousKeys` (a Set of "RULE|location" for findings open from the last browser scan) drives the
// disappearance rule: a finding that vanishes is confirmed by one fresh-cache re-run before it is allowed
// to count as fixed, because a transient load failure looks exactly like a fix.
export async function runBrowserScan({ targetUrl, options = {}, deps = {}, previousKeys = new Set(), cap = MAX_PAGES, contextOptions = {} }) {
  const d = { ...defaultDeps, ...deps };
  // OPS-001: scan only once the change being checked is live. If it never appears, say so and scan anyway.
  const deploy = options.wait_for ? await waitForDeploy({ url: options.wait_for.url ?? targetUrl, ...options.wait_for, fetchImpl: d.fetchImpl }) : null;
  const browser = await launchBrowser();
  const t0 = Date.now();
  try {
    let run = await pass({ targetUrl, options, deps: d, browser, cap, contextOptions });
    let retried = false;
    const siteHost = new URL(run.origin).hostname;
    await confirmFailedRequests({ pages: run.pages, siteHost, fetchStatus: d.fetchStatus });
    let ev = evaluateAll({ pages: run.pages, origin: run.origin, siteHost, fetchStatus: d.fetchStatus });
    const keysOf = (res) => new Set(res.flatMap((r) => r.findings).map((f) => `${f.rule_id}|${f.location}`));
    const missing = [...previousKeys].filter((k) => !keysOf(ev.results).has(k));
    if (missing.length && !options.cache_bust) {
      retried = true;
      run = await pass({ targetUrl, options: { ...options, cache_bust: true }, deps: d, browser, cap, contextOptions });
      await confirmFailedRequests({ pages: run.pages, siteHost, fetchStatus: d.fetchStatus });
      ev = evaluateAll({ pages: run.pages, origin: run.origin, siteHost, fetchStatus: d.fetchStatus });
    }

    const sms = await evaluateSmsConsent({ pages: ev.loaded, origin: run.origin, fetchStatus: d.fetchStatus });
    const findings = [...ev.results.flatMap((r) => r.findings), ...sms.findings];
    const checks = [...ev.results.flatMap((r) => r.checks), ...sms.checks];
    if (deploy && !deploy.ok) checks.push({ rule_id: "OPS-001", outcome: "needs_review", detail: `Waited for a deploy marker and it did not appear: ${deploy.reason}. The scan ran anyway, so these results may describe the previous version.`, evidence_keys: [] });
    else if (deploy?.waited) checks.push({ rule_id: "OPS-001", outcome: "passed", detail: `The expected change appeared on the live site after ${Math.round(deploy.ms / 1000)} s (${deploy.attempts} check${deploy.attempts === 1 ? "" : "s"}) before scanning.`, evidence_keys: [] });

    // Group C: only ever with a stored authorization, decided in SQL and re-checked here. Whatever stops
    // it, the report says so rather than going silent.
    const activeEvidence = [];
    const skip = (id, why) => ({ rule_id: id, outcome: "skipped", detail: why, evidence_keys: [] });
    if (!options.active_tests) {
      const why = options.active_tests_requested ? "Requested, but the site has no current authorization on file (or the daily limit was reached), so it was not run." : "Not requested. Active tests send data to the site and are off by default.";
      checks.push(skip("FORM-010", why), skip("FORM-011", why));
    } else {
      // Pick the first form whose destination is known: observed through a script, or a real https action.
      let target = null;
      for (const p of ev.loaded) for (const [i, f] of (p.forms ?? []).entries()) {
        if (target) break;
        const obs = f.observed?.requests?.find((r) => r.method !== "GET");
        if (obs) target = { p, i, f, template: obs, hiddenFields: f.observed.hiddenFields ?? [] };
        else if (/^https:/i.test(f.action) && f.rawAction && f.rawAction.trim() !== "#") target = { p, i, f, template: null, hiddenFields: [] };
      }
      if (!target) {
        checks.push(skip("FORM-010", "No form with a known destination was found to test."), skip("FORM-011", "No form with a known destination was found to test."));
      } else {
        const endpoint = target.template?.url ?? target.f.action;
        const gate = activeTestsPermitted({ options, verified: options.verified === true, siteHost, endpointUrl: endpoint });
        if (!gate.ok) {
          checks.push(skip("FORM-010", `Not run: ${gate.reason}.`), skip("FORM-011", `Not run: ${gate.reason}.`));
        } else {
          if (target.template) {
            const cases = buildMatrix({ template: target.template, hiddenFields: target.hiddenFields, origin: run.origin });
            const results = await runMatrix({ cases, fetchImpl: d.fetchImpl ?? fetch });
            const m = evaluateMatrix({ results, origin: run.origin });
            findings.push(...m.findings); checks.push(...m.checks);
            activeEvidence.push({ key: "active_matrix", kind: "active_test", url: endpoint, raw: { test: "FORM-010 endpoint validation matrix", markers: { name: "CAVSCOPE TEST (delete me)", email: "cavscope-test@example.com" }, results } });
          } else {
            checks.push(skip("FORM-010", "The form submits natively; its request body is not known without sending, so the matrix was not built."));
          }
          const ctx = await newScanContext(browser, { contextOptions });
          const live = await liveSubmit(ctx, target.p.finalUrl || target.p.url, target.i);
          await ctx.close().catch(() => {});
          const l = evaluateLiveSubmit({ res: live, origin: run.origin });
          findings.push(...l.findings); checks.push(...l.checks);
          activeEvidence.push({ key: "active_submit", kind: "active_test", url: live.pageUrl, raw: { test: "FORM-011 live end-to-end submit", markers: { name: "CAVSCOPE TEST (delete me)", email: "cavscope-test@example.com", phone: "5555550100" }, ...live } });
        }
      }
    }

    // OPS-002: where DNS is managed, so a DNS fix tells the client where to make it.
    const apex = registrableDomain(siteHost);
    const ns = await d.resolveNs(apex);

    const evidence = [];
    const add = (e) => evidence.push(evidenceRow(e));
    for (const p of run.pages) {
      add({ key: p.evidenceKey, kind: "browser_page", url: p.finalUrl || p.url, status: p.status ?? null, ms: p.ms ?? null,
        raw: { url: p.url, finalUrl: p.finalUrl, status: p.status, contentType: p.contentType, loadMs: p.ms, navigationAttempts: p.attempts, cacheBust: p.cacheBust ?? false, error: p.error ?? null, structure: p.structure ?? null, requestCount: p.requests.length } });
      if (p.error) continue;
      if (p.axe) add({ key: p.evidenceKey + "_axe", kind: "axe_results", url: p.finalUrl, raw: { axeVersion: p.axe.version, tags: p.axe.tags, injection: p.axe.injection, passes: p.axe.passes, violations: p.axe.violations, incomplete: p.axe.incomplete, contrastResolved: p.contrast ?? [] } });
      add({ key: p.evidenceKey + "_console", kind: "console_log", url: p.finalUrl, raw: { console: p.console, failedRequests: p.requests.filter((r) => r.failed && !r.aborted) } });
      if (p.forms?.length) add({ key: p.evidenceKey + "_forms", kind: "form_inventory", url: p.finalUrl, raw: p.forms.map((f) => ({ id: f.id, name: f.name, rawAction: f.rawAction, action: f.action, method: f.method, hasPassword: f.hasPassword, hasPayment: f.hasPayment, fields: f.fields.map(({ name, id, type, required, checked, autocomplete }) => ({ name, id, type, required, checked, autocomplete })), links: f.links, nearText: f.nearText.slice(0, 600), observedSubmission: f.observed ? { networkBlocked: true, requests: f.observed.requests.map(({ url, method, contentType }) => ({ url, method, contentType })) } : null })) });
    }
    const inv = ev.results[2].inventory ?? { total: 0, hosts: [] };
    add({ key: "requests", kind: "request_list", url: run.origin, raw: { totalRequests: inv.total, thirdPartyHostCount: inv.hosts.length, thirdPartyHosts: inv.hosts, firstPartyDomain: apex, perPage: run.pages.filter((p) => !p.error).map((p) => ({ page: p.finalUrl, requests: p.requests.map((r) => ({ url: r.url.slice(0, 200), type: r.resourceType, status: r.status })) })) } });
    const first = run.pages[0];
    if (first && !first.error) {
      add({ key: "cookies", kind: "cookie_jar", url: first.finalUrl, raw: { observed: "after first load, before any click, scroll or consent action", count: first.cookies.length, cookies: first.cookies } });
      if (first.cspProbe) add({ key: "csp_probe", kind: "csp_probe", url: first.finalUrl, raw: { script: "window.__cavscopeCspProbe = 1 (harmless)", ...first.cspProbe, axeInjection: first.axe?.injection ?? null, note: "axe-core is injected through the DevTools protocol; the page's CSP was not bypassed or altered." } });
    }
    for (const e of activeEvidence) add(e);
    add({ key: "dns_ns", kind: "dns_ns", url: `dns:${apex}?type=NS`, raw: { ns, provider: dnsProvider(ns) } });

    const loaded = run.pages.filter((p) => !p.error).length;
    return {
      scan: {
        engine_version: ENGINE_VERSION, final_url: first?.finalUrl ?? targetUrl, http_status: first?.status ?? null, response_ms: Date.now() - t0,
        pages_visited: loaded,
        browser_checks: checks,
        detail: { discovery: run.discovery, pagesAttempted: run.pages.length, pagesFailed: run.pages.length - loaded, deployWait: deploy, retriedForDisappeared: retried, missingBeforeRetry: missing, dnsProvider: dnsProvider(ns), axeVersion: AXE_VERSION },
      },
      evidence, findings,
    };
  } finally {
    await browser.close().catch(() => {});
  }
}
