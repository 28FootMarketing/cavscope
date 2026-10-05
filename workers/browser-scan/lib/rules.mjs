// Rule evaluation for the browser engine. Pure: takes what the collector saw, returns findings and a
// per-rule outcome. Nothing here touches a page, the network or the database, so every branch is
// unit-testable and the same evaluator runs on a real scan and on a local fixture.
//
// Contract with the report: every rule produces a `check` (outcome passed | finding | needs_review |
// not_applicable | skipped), so a clean result is listed as a result rather than left as silence.
// A passed check means "these checks found nothing on this date". It is never "compliant".
//
// A finding has the shape engine_ingest takes: { rule_id, severity, title, detail, page_url, location,
// confidence, evidence_keys }.

import { isFirstParty, isTrackerCookie, isTrackerHost, registrableDomain } from "./hosts.mjs";

const SEVERITY_BY_IMPACT = { critical: "high", serious: "medium", moderate: "low", minor: "info" };
const SEVERITY_RANK = { high: 3, medium: 2, low: 1, info: 0 };
const maxSeverity = (a, b) => (SEVERITY_RANK[a] >= SEVERITY_RANK[b] ? a : b);
const pageLabel = (p) => { try { const u = new URL(p.finalUrl || p.url); return u.pathname + u.search || "/"; } catch { return p.url; } };
const list = (arr, n = 8) => (arr.length > n ? arr.slice(0, n).join(", ") + `, and ${arr.length - n} more` : arr.join(", "));

const check = (rule_id, outcome, detail, evidence_keys = []) => ({ rule_id, outcome, detail, evidence_keys });
const finding = (f) => ({ confidence: "high", evidence_keys: [], page_url: null, location: null, ...f });

// ---------------------------------------------------------------------------------------------------
// A11Y-008, A11Y-009: axe-core
// ---------------------------------------------------------------------------------------------------
export function evaluateAxe({ pages, origin, axeVersion }) {
  const axePages = pages.filter((p) => p.axe);
  if (axePages.length === 0)
    return { findings: [], checks: [check("A11Y-008", "not_applicable", "No page could be analysed by axe-core."), check("A11Y-009", "not_applicable", "No page could be analysed by axe-core.")] };

  const byRule = new Map();
  for (const p of axePages) {
    for (const v of p.axe.violations ?? []) {
      const e = byRule.get(v.id) ?? { id: v.id, help: v.help, helpUrl: v.helpUrl, impact: "minor", severity: "info", pages: [], nodes: 0, keys: [], sample: [] };
      const sev = SEVERITY_BY_IMPACT[v.impact] ?? "low";
      e.severity = e.pages.length === 0 ? sev : maxSeverity(e.severity, sev);
      e.pages.push({ label: pageLabel(p), nodes: v.nodes.length });
      if (p.degraded) e.degraded = true;
      e.nodes += v.nodes.length;
      e.keys.push(p.evidenceKey + "_axe");
      for (const n of v.nodes.slice(0, 2)) if (e.sample.length < 3) e.sample.push(`${n.target?.join(" ")}: ${String(n.html).slice(0, 140)}`);
      byRule.set(v.id, e);
    }
  }

  // Contrast incompletes that CavScope could settle from computed colours.
  const resolved = pages.flatMap((p) => (p.contrast ?? []).map((c) => ({ ...c, page: pageLabel(p), key: p.evidenceKey + "_axe" })));
  const resolvedFail = resolved.filter((c) => c.status === "fail");
  const resolvedPass = resolved.filter((c) => c.status === "pass");
  const unresolved = resolved.filter((c) => c.status === "unresolved");

  const findings = [];
  for (const e of [...byRule.values()].sort((a, b) => a.id.localeCompare(b.id))) {
    findings.push(finding({
      rule_id: "A11Y-008", severity: e.severity, location: e.id, page_url: origin,
      title: `Rendered accessibility: ${e.help}`,
      detail: `axe-core rule "${e.id}" failed on ${e.pages.length} page${e.pages.length === 1 ? "" : "s"} (${e.nodes} element${e.nodes === 1 ? "" : "s"}): ${list(e.pages.map((x) => `${x.label} (${x.nodes})`))}. Example: ${e.sample[0] ?? "see evidence"}. ${e.helpUrl ?? ""}`.trim(),
      evidence_keys: [...new Set(e.keys)],
      ...(e.degraded ? { confidence: "low" } : {}),
    }));
    if (e.degraded) findings[findings.length - 1].detail += " One or more of these pages lost some of its own files while loading, so its layout may differ from what visitors see; rescan to confirm.";
  }
  if (resolvedFail.length) {
    findings.push(finding({
      rule_id: "A11Y-008", severity: "medium", location: "color-contrast (resolved)", page_url: origin,
      title: "Rendered accessibility: text contrast below the WCAG ratio",
      detail: `axe-core could not settle ${resolvedFail.length} contrast check${resolvedFail.length === 1 ? "" : "s"} (gradient or image backgrounds); CavScope resolved them from the page's computed colours and they fall short. Weakest: ${resolvedFail.sort((a, b) => a.ratio - b.ratio).slice(0, 3).map((c) => `${c.page} ${c.target}: ${c.ratio}:1, needs ${c.required}:1`).join("; ")}.`,
      confidence: "medium", evidence_keys: [...new Set(resolvedFail.map((c) => c.key))],
    }));
  }

  // Needs review: every other incomplete, plus contrast cases that could not be resolved.
  const incByRule = new Map();
  for (const p of axePages) {
    for (const inc of p.axe.incomplete ?? []) {
      if (inc.id === "color-contrast") continue; // handled through `resolved` above
      const e = incByRule.get(inc.id) ?? { id: inc.id, help: inc.help, pages: new Set(), nodes: 0, sample: [], keys: new Set() };
      e.pages.add(pageLabel(p)); e.nodes += inc.nodes.length; e.keys.add(p.evidenceKey + "_axe");
      for (const n of inc.nodes.slice(0, 2)) if (e.sample.length < 3) e.sample.push(`${n.target?.join(" ")}: ${String(n.html).slice(0, 140)} (${n.message ?? n.failureSummary ?? "needs review"})`);
      incByRule.set(inc.id, e);
    }
  }
  if (unresolved.length) {
    incByRule.set("color-contrast", {
      id: "color-contrast", help: "Text contrast needs review", nodes: unresolved.length,
      pages: new Set(unresolved.map((c) => c.page)), keys: new Set(unresolved.map((c) => c.key)),
      sample: unresolved.slice(0, 3).map((c) => `${c.target}: ${c.reason}`),
    });
  }
  for (const e of [...incByRule.values()].sort((a, b) => a.id.localeCompare(b.id))) {
    findings.push(finding({
      rule_id: "A11Y-009", severity: "info", location: e.id, page_url: origin, confidence: "low",
      title: `Needs review: ${e.help}`,
      detail: `Needs review, not a pass or a fail. axe-core could not decide "${e.id}" on ${e.pages.size} page${e.pages.size === 1 ? "" : "s"} (${e.nodes} element${e.nodes === 1 ? "" : "s"}). Example: ${e.sample[0] ?? "see evidence"}.`,
      evidence_keys: [...e.keys],
    }));
  }

  const otherInc = [...incByRule.values()].filter((e) => e.id !== "color-contrast").length;
  const viol = findings.filter((f) => f.rule_id === "A11Y-008").length;
  const totalNodes = [...byRule.values()].reduce((n, e) => n + e.nodes, 0);
  const checks = [
    viol === 0
      ? check("A11Y-008", "passed", `axe-core ${axeVersion ?? ""} found 0 violations on ${axePages.length} of ${pages.length} pages (WCAG 2.0/2.1/2.2 A and AA, and best-practice rules). Automated rules find only part of what a person would.`.replace("  ", " "), axePages.map((p) => p.evidenceKey + "_axe"))
      : check("A11Y-008", "finding", `${viol} distinct issue${viol === 1 ? "" : "s"} across ${axePages.length} pages (${totalNodes} elements).`, axePages.map((p) => p.evidenceKey + "_axe")),
    check("A11Y-009", findings.some((f) => f.rule_id === "A11Y-009") ? "needs_review" : "passed",
      `${resolvedPass.length} contrast check${resolvedPass.length === 1 ? "" : "s"} resolved as passing from computed colours, ${resolvedFail.length} as failing, ${unresolved.length} left for review; ${otherInc} other axe rule${otherInc === 1 ? "" : "s"} need${otherInc === 1 ? "s" : ""} review.`,
      axePages.map((p) => p.evidenceKey + "_axe")),
  ];
  return { findings, checks };
}

// ---------------------------------------------------------------------------------------------------
// A11Y-010: page structure
// ---------------------------------------------------------------------------------------------------
const LANG_RE = /^[a-z]{2,3}(-[a-z0-9]{2,8})*$/i;
export function evaluateStructure({ pages, origin }) {
  const ok = pages.filter((p) => p.structure);
  if (ok.length === 0) return { findings: [], checks: [check("A11Y-010", "not_applicable", "No page could be read.")] };
  const probs = { title: [], h1: [], lang: [], alt: [] };
  for (const p of ok) {
    const s = p.structure;
    if (!s.title || !s.title.trim()) probs.title.push(pageLabel(p));
    if (s.h1Count !== 1) probs.h1.push(`${pageLabel(p)} (${s.h1Count})`);
    if (!s.lang || !LANG_RE.test(s.lang.trim())) probs.lang.push(`${pageLabel(p)} (${s.lang ? `"${s.lang}"` : "missing"})`);
    if (s.imgNoAlt > 0) probs.alt.push(`${pageLabel(p)} (${s.imgNoAlt})`);
  }
  const defs = [
    ["title", "medium", "Pages without a title", "has no <title> or an empty one"],
    ["h1", "low", "Pages without exactly one main heading", "does not have exactly one <h1> (count shown)"],
    ["lang", "medium", "Pages without a valid language declared", "has a missing or invalid <html lang>"],
    ["alt", "medium", "Images with no alt attribute", "has images with no alt attribute (count shown)"],
  ];
  const findings = [];
  for (const [k, sev, title, what] of defs) {
    if (probs[k].length === 0) continue;
    findings.push(finding({
      rule_id: "A11Y-010", severity: sev, title, location: k, page_url: origin,
      detail: `${probs[k].length} of ${ok.length} rendered page${ok.length === 1 ? "" : "s"} ${what}: ${list(probs[k])}.`,
      evidence_keys: ok.map((p) => p.evidenceKey),
    }));
  }
  const imgs = ok.reduce((n, p) => n + p.structure.imgTotal, 0);
  return {
    findings,
    checks: [findings.length === 0
      ? check("A11Y-010", "passed", `${ok.length} page${ok.length === 1 ? "" : "s"}: each has a title, exactly one h1, a valid html lang, and ${imgs} image${imgs === 1 ? "" : "s"} all with an alt attribute.`, ok.map((p) => p.evidenceKey))
      : check("A11Y-010", "finding", `${findings.length} structure issue${findings.length === 1 ? "" : "s"} across ${ok.length} pages.`, ok.map((p) => p.evidenceKey))],
  };
}

// ---------------------------------------------------------------------------------------------------
// TP-002: third-party requests
// ---------------------------------------------------------------------------------------------------
export function thirdPartyInventory({ pages, siteHost }) {
  const hosts = new Map();
  let total = 0;
  for (const p of pages) {
    for (const r of p.requests ?? []) {
      total++;
      if (!r.host || isFirstParty(r.host, siteHost)) continue;
      const e = hosts.get(r.host) ?? { host: r.host, count: 0, types: new Set(), pages: new Set() };
      e.count++; e.types.add(r.resourceType); e.pages.add(pageLabel(p));
      hosts.set(r.host, e);
    }
  }
  return { total, hosts: [...hosts.values()].map((h) => ({ host: h.host, count: h.count, types: [...h.types].sort(), pages: [...h.pages].sort() })).sort((a, b) => b.count - a.count) };
}

export function evaluateThirdParties({ pages, siteHost, origin }) {
  const withReq = pages.filter((p) => p.requests);
  if (withReq.length === 0) return { findings: [], checks: [check("TP-002", "not_applicable", "No page loaded.")], inventory: { total: 0, hosts: [] } };
  const inv = thirdPartyInventory({ pages: withReq, siteHost });
  const first = registrableDomain(siteHost);
  if (inv.hosts.length === 0)
    return { findings: [], inventory: inv, checks: [check("TP-002", "passed", `0 third-party hosts: all ${inv.total} requests across ${withReq.length} page${withReq.length === 1 ? "" : "s"} went to ${first} (the site's own registered domain).`, ["requests"])] };
  return {
    inventory: inv,
    findings: [finding({
      rule_id: "TP-002", severity: "info", location: "third_party_hosts", page_url: origin,
      title: `${inv.hosts.length} third-party host${inv.hosts.length === 1 ? "" : "s"} contacted by the rendered pages`,
      detail: inv.hosts.slice(0, 12).map((h) => `${h.host}: ${h.count} request${h.count === 1 ? "" : "s"} (${h.types.join("/")}) on ${h.pages.length} page${h.pages.length === 1 ? "" : "s"}`).join("; ") + (inv.hosts.length > 12 ? `; and ${inv.hosts.length - 12} more` : "") + `. First-party means ${first}.`,
      evidence_keys: ["requests"],
    })],
    checks: [check("TP-002", "finding", `${inv.hosts.length} third-party host${inv.hosts.length === 1 ? "" : "s"} across ${inv.total} requests.`, ["requests"])],
  };
}

// ---------------------------------------------------------------------------------------------------
// PRIV-006: cookies and trackers before interaction
// ---------------------------------------------------------------------------------------------------
export function evaluateCookies({ firstLoad, siteHost, origin }) {
  if (!firstLoad) return { findings: [], checks: [check("PRIV-006", "not_applicable", "The first page did not load, so nothing could be observed before interaction.")] };
  const cookies = firstLoad.cookies ?? [];
  const trackerCookies = cookies.filter((c) => isTrackerCookie(c.name));
  const trackerHosts = [...new Set((firstLoad.requests ?? []).map((r) => r.host).filter((h) => h && isTrackerHost(h)))];
  if (cookies.length === 0 && trackerHosts.length === 0)
    return { findings: [], checks: [check("PRIV-006", "passed", "0 cookies and 0 known tracker hosts observed before interaction (after first load, before any click, scroll or consent action).", ["cookies"])] };
  if (trackerCookies.length === 0 && trackerHosts.length === 0)
    return { findings: [], checks: [check("PRIV-006", "passed", `${cookies.length} cookie${cookies.length === 1 ? "" : "s"} observed before interaction (${list(cookies.map((c) => c.name))}); none match known advertising or analytics cookies, and no known tracker host was requested.`, ["cookies"])] };
  const parts = [];
  if (trackerCookies.length) parts.push(`advertising or analytics cookies set: ${list(trackerCookies.map((c) => c.name))}`);
  if (trackerHosts.length) parts.push(`known tracker hosts requested: ${list(trackerHosts)}`);
  return {
    findings: [finding({
      rule_id: "PRIV-006", severity: "medium", location: "before_interaction", page_url: origin,
      title: "Cookies or trackers observed before any interaction",
      detail: `Observed before interaction (after first load, before any click, scroll or consent action): ${parts.join("; ")}. This reports what was observed; whether it is a problem depends on your privacy policy and on the laws that apply to your visitors.`,
      evidence_keys: ["cookies", "requests"],
    })],
    checks: [check("PRIV-006", "finding", parts.join("; "), ["cookies", "requests"])],
  };
}

// ---------------------------------------------------------------------------------------------------
// SEC-021 / SEC-022: CSP
// ---------------------------------------------------------------------------------------------------
export function evaluateCspConsole({ pages, siteHost, origin }) {
  const ok = pages.filter((p) => p.console);
  if (ok.length === 0) return { findings: [], checks: [check("SEC-021", "not_applicable", "No page loaded.")] };
  const cspMsgs = [];
  const failed = [];
  for (const p of ok) {
    for (const m of p.console) {
      if ((m.type === "error" || m.type === "warning" || m.type === "warn") && /content security policy|refused to/i.test(m.text))
        cspMsgs.push({ page: pageLabel(p), text: m.text.replace(/\s+/g, " ").slice(0, 200), key: p.evidenceKey + "_console" });
    }
    for (const r of p.requests ?? []) {
      if (r.failed && r.host && isFirstParty(r.host, siteHost) && !r.aborted && !r.transient)
        failed.push({ page: pageLabel(p), url: r.url.slice(0, 160), why: r.failureText ?? "failed", key: p.evidenceKey + "_console" });
    }
  }
  const findings = [];
  if (cspMsgs.length)
    findings.push(finding({
      rule_id: "SEC-021", severity: "medium", location: "csp-console", page_url: origin,
      title: "The Content Security Policy blocked something on the site's own pages",
      detail: `${cspMsgs.length} browser console message${cspMsgs.length === 1 ? "" : "s"} reported a policy refusal. First: ${cspMsgs[0].text} (${cspMsgs[0].page}).`,
      evidence_keys: [...new Set(cspMsgs.map((m) => m.key))],
    }));
  if (failed.length)
    findings.push(finding({
      rule_id: "SEC-021", severity: "medium", location: "first-party-failed", page_url: origin,
      title: "A first-party asset failed to load",
      detail: `${failed.length} request${failed.length === 1 ? "" : "s"} to the site's own domain failed: ${list(failed.map((f) => `${f.url} (${f.why}) on ${f.page}`), 4)}.`,
      evidence_keys: [...new Set(failed.map((m) => m.key))],
    }));
  return {
    findings,
    checks: [findings.length === 0
      ? check("SEC-021", "passed", `0 Content Security Policy console violations and 0 failed first-party requests across ${ok.length} page${ok.length === 1 ? "" : "s"}.`, ok.map((p) => p.evidenceKey + "_console"))
      : check("SEC-021", "finding", `${cspMsgs.length} policy message${cspMsgs.length === 1 ? "" : "s"}, ${failed.length} failed first-party request${failed.length === 1 ? "" : "s"}.`, ok.map((p) => p.evidenceKey + "_console"))],
  };
}

export function evaluateCspProbe({ probe, origin }) {
  if (!probe) return { findings: [], checks: [check("SEC-022", "not_applicable", "No page was available for the inline script test.")] };
  if (probe.executed === false)
    return { findings: [], checks: [check("SEC-022", "passed", `The browser refused a harmless injected inline script on ${probe.page}: the Content Security Policy is enforced against inline script.`, ["csp_probe"])] };
  return {
    findings: [finding({
      rule_id: "SEC-022", severity: "info", location: "inline-script-executed", page_url: origin,
      title: "A harmless injected inline script ran",
      detail: `On ${probe.page}, a harmless inline script (it only set a window variable) executed, so no Content Security Policy is stopping injected inline script on that page.`,
      evidence_keys: ["csp_probe"],
    })],
    checks: [check("SEC-022", "finding", `An injected inline script executed on ${probe.page}.`, ["csp_probe"])],
  };
}

// ---------------------------------------------------------------------------------------------------
// FORM-001, FORM-002, FORM-003
// ---------------------------------------------------------------------------------------------------
const badAction = (raw) => raw == null || raw.trim() === "" || raw.trim() === "#" || /^javascript:/i.test(raw.trim());
const formLabel = (f, i) => f.id ? `#${f.id}` : f.name ? `[name=${f.name}]` : `form ${i + 1}`;

export function evaluateForms001({ pages, origin }) {
  const forms = pages.flatMap((p) => (p.forms ?? []).map((f, i) => ({ f, i, p })));
  if (forms.length === 0) return { findings: [], checks: [check("FORM-001", "not_applicable", "No forms found on the rendered pages.", [])] };
  const findings = [];
  const targets = [];
  for (const { f, i, p } of forms) {
    const where = `${pageLabel(p)} ${formLabel(f, i)}`;
    const keyOf = p.evidenceKey + "_forms";
    if (badAction(f.rawAction)) {
      // No usable action: a script submits it, or nothing does. The collector filled the form with test
      // values and watched where it tried to send them with the network blocked, so we can say which.
      const obs = f.observed;
      const sent = (obs?.requests ?? []).filter((r) => r.method !== "GET");
      if (sent.length > 0) {
        const ep = sent[0];
        let https = false; let host = "?";
        try { const u = new URL(ep.url); https = u.protocol === "https:"; host = u.host; } catch { /* keep defaults */ }
        targets.push({ where, ep, host, https });
        if (!https) findings.push(finding({
          rule_id: "FORM-001", severity: "high", location: `${pageLabel(p)}|${formLabel(f, i)}|http`, page_url: p.finalUrl || p.url,
          title: "A form submits over an unencrypted connection",
          detail: `The form ${where} has no action attribute, and when submitted its script tried to ${ep.method} to ${ep.url}, which is not HTTPS. The request was blocked in the browser; nothing was sent.`,
          evidence_keys: [keyOf],
        }));
        continue;
      }
      findings.push(finding({
        rule_id: "FORM-001", severity: "high", location: `${pageLabel(p)}|${formLabel(f, i)}|action`, page_url: p.finalUrl || p.url, confidence: obs ? "high" : "medium",
        title: "A form does not submit anywhere",
        detail: `The form ${where} has ${f.rawAction == null ? "no action attribute" : `action "${f.rawAction}"`}, so submitting it as written goes nowhere. ${obs ? "It was also filled with test values and submitted in the browser with the network blocked, and no request to send the data was attempted." : "If a script submits it instead, confirm that script posts to an HTTPS endpoint; this check could not observe one."}`,
        evidence_keys: [keyOf],
      }));
    } else if (!/^https:/i.test(f.action)) {
      findings.push(finding({
        rule_id: "FORM-001", severity: "high", location: `${pageLabel(p)}|${formLabel(f, i)}|http`, page_url: p.finalUrl || p.url,
        title: "A form submits over an unencrypted connection",
        detail: `The form ${where} posts to ${f.action}, which is not HTTPS. What visitors type${f.hasPassword || f.hasPayment ? ", including a password or payment field," : ""} is sent without encryption.`,
        evidence_keys: [keyOf],
      }));
    } else {
      try { targets.push({ where, ep: { method: f.method.toUpperCase(), url: f.action }, host: new URL(f.action).host, https: true }); } catch { /* ignore */ }
    }
  }
  const sensitive = forms.filter(({ f }) => f.hasPassword || f.hasPayment).length;
  const keys = [...new Set(forms.map(({ p }) => p.evidenceKey + "_forms"))];
  const viaScript = targets.filter((t) => forms.some(({ f }) => badAction(f.rawAction) && f.observed?.requests?.length)).length;
  return {
    findings,
    checks: [findings.length === 0
      ? check("FORM-001", "passed", `${forms.length} form${forms.length === 1 ? "" : "s"} found; each submits over HTTPS to ${list([...new Set(targets.map((t) => t.host))], 4)}${viaScript ? ` (${viaScript} through a script: the form was filled with test values and submitted with the network blocked, so the destination was observed and nothing was sent)` : ""}${sensitive ? `; ${sensitive} collect${sensitive === 1 ? "s" : ""} a password or payment field` : ""}.`, keys)
      : check("FORM-001", "finding", `${findings.length} of ${forms.length} form${forms.length === 1 ? "" : "s"} with a submission problem.`, keys)],
  };
}

const RE = {
  stop: /\bSTOP\b/i,
  help: /\bHELP\b/i,
  rates: /message\s*(?:and|&)\s*data\s*rates?|msg\s*(?:and|&)\s*data\s*rates?|data\s*rates?\s*may\s*apply/i,
  freq: /message\s*frequency|msg\s*frequency|frequency\s*(?:varies|may vary)|up to \d+\s*(?:messages|msgs|texts)/i,
  notCondition: /not\s*(?:a\s*)?condition\s*of\s*(?:any\s*)?(?:purchase|service|participation)/i,
  phoneField: /phone|mobile|\btel\b|cell|sms/i,
  smsConsent: /\bsms\b|text\s*message|\btexts?\b|mobile\s*messages?/i,
};

export const isPhoneField = (fld) => fld.type === "tel" || RE.phoneField.test(`${fld.name} ${fld.id} ${fld.autocomplete}`);
export const isSmsConsentBox = (fld, contextText) => fld.type === "checkbox" && RE.smsConsent.test(`${fld.label} ${contextText}`);

// `fetchStatus(url)` is injected by the engine (a real HTTP check) so this stays pure; tests pass a fake.
export async function evaluateSmsConsent({ pages, origin, fetchStatus }) {
  const cases = [];
  for (const p of pages) for (const [i, f] of (p.forms ?? []).entries()) {
    const phone = f.fields.find(isPhoneField);
    const consent = f.fields.find((fld) => isSmsConsentBox(fld, f.nearText ?? ""));
    if (phone || consent) cases.push({ p, f, i, phone, consent });
  }
  if (cases.length === 0) return { findings: [], checks: [check("FORM-002", "not_applicable", "No form with a phone field or text-message consent box was found.", [])] };

  const findings = [];
  const summaries = [];
  for (const { p, f, i, phone, consent } of cases) {
    const text = `${consent?.label ?? ""} ${f.nearText ?? ""}`;
    const links = f.links ?? [];
    const privacy = links.find((l) => /privacy/i.test(l.text) || /privacy/i.test(l.href));
    const terms = links.find((l) => /\bsms\b|text\s*(message)?\s*terms|messaging\s*terms|terms/i.test(l.text) && l !== privacy);
    const status = async (l) => (l ? await fetchStatus(l.href) : null);
    const privacyStatus = await status(privacy);
    const termsStatus = await status(terms);
    const items = [
      ["Consent box is not pre-checked", consent ? !consent.checked : false, consent ? (consent.checked ? "the consent box is checked by default" : "ok") : "no consent checkbox found"],
      ["Mentions STOP", RE.stop.test(text), "no STOP wording near the consent text"],
      ["Mentions HELP", RE.help.test(text), "no HELP wording near the consent text"],
      ["Mentions message and data rates", RE.rates.test(text), "no message and data rates wording"],
      ["Mentions message frequency", RE.freq.test(text), "no message frequency wording"],
      ["Links to a Privacy Policy that returns HTTP 200", privacyStatus === 200, privacy ? `${privacy.href} returned ${privacyStatus ?? "no response"}` : "no privacy policy link near the consent text"],
      ["Links to SMS terms that return HTTP 200", termsStatus === 200, terms ? `${terms.href} returned ${termsStatus ?? "no response"}` : "no SMS or terms link near the consent text"],
      ["States consent is not a condition of purchase", RE.notCondition.test(text), "no 'not a condition of purchase' statement"],
      ["Phone is not required unless consent is", !(phone?.required && !consent?.required), "the phone field is required but the consent box is not"],
    ];
    const failedItems = items.filter(([, ok]) => !ok);
    const lines = items.map(([name, ok, why]) => `${ok ? "pass" : "fail"}: ${name}${ok ? "" : ` (${why})`}`);
    summaries.push(`${pageLabel(p)} ${formLabel(f, i)}: ${items.length - failedItems.length}/${items.length}`);
    if (failedItems.length)
      findings.push(finding({
        rule_id: "FORM-002", severity: "medium", location: `${pageLabel(p)}|${formLabel(f, i)}`, page_url: p.finalUrl || p.url,
        title: "Text-message consent is missing items carriers look for",
        detail: `${failedItems.length} of ${items.length} checks failed on ${pageLabel(p)} ${formLabel(f, i)}. ${lines.join("; ")}. This is evidence for carrier registration readiness, not legal advice.`,
        evidence_keys: [p.evidenceKey + "_forms"],
      }));
    else
      summaries[summaries.length - 1] += ` (${lines.length} of ${lines.length} passed)`;
  }
  return {
    findings,
    checks: [findings.length === 0
      ? check("FORM-002", "passed", `${cases.length} form${cases.length === 1 ? "" : "s"} with a phone field or consent box: all nine readiness checks passed (${summaries.join("; ")}). Evidence for carrier registration readiness, not legal advice.`, [...new Set(cases.map(({ p }) => p.evidenceKey + "_forms"))])
      : check("FORM-002", "finding", `${findings.length} of ${cases.length} form${cases.length === 1 ? "" : "s"} missing readiness items.`, [...new Set(cases.map(({ p }) => p.evidenceKey + "_forms"))])],
  };
}

const MINORS_PAGE = /\b(athletes?|students?|youth|kids?|children|child|parents?|teens?|juniors?)\b/i;
const MINORS_NOTICE = /parent|guardian|under\s*(?:the\s*age\s*of\s*)?18|minor|13\s*(?:years|or older)|age\s*of\s*(?:consent|majority)/i;
const PERSONAL_FIELD = /e-?mail|phone|tel|name|address|birth|dob/i;

export function evaluateMinors({ pages, origin }) {
  const cases = [];
  for (const p of pages) {
    if (!p.forms?.length || !MINORS_PAGE.test(p.textSample ?? "")) continue;
    for (const [i, f] of p.forms.entries()) {
      if (!f.fields.some((fld) => fld.type === "email" || fld.type === "tel" || PERSONAL_FIELD.test(`${fld.name} ${fld.id} ${fld.autocomplete}`))) continue;
      cases.push({ p, f, i, notice: MINORS_NOTICE.test(f.nearText ?? "") });
    }
  }
  if (cases.length === 0) return { findings: [], checks: [check("FORM-003", "not_applicable", "No form that collects personal data was found on a page that mentions youth, students, athletes or parents.", [])] };
  const missing = cases.filter((c) => !c.notice);
  const findings = missing.map(({ p, f, i }) => finding({
    rule_id: "FORM-003", severity: "info", location: `${pageLabel(p)}|${formLabel(f, i)}`, page_url: p.finalUrl || p.url, confidence: "medium",
    title: "Consider a parent or guardian notice near this form",
    detail: `${pageLabel(p)} mentions young people (athletes, students, youth or parents) and ${formLabel(f, i)} collects personal data, but no parent, guardian or under-18 notice was found near it. Consider adding one. This is a prompt to review, not a legal conclusion.`,
    evidence_keys: [p.evidenceKey + "_forms"],
  }));
  return {
    findings,
    checks: [findings.length === 0
      ? check("FORM-003", "passed", `${cases.length} form${cases.length === 1 ? "" : "s"} on youth-facing pages; each has a parent, guardian or under-18 notice nearby.`, [...new Set(cases.map(({ p }) => p.evidenceKey + "_forms"))])
      : check("FORM-003", "finding", `${findings.length} of ${cases.length} form${cases.length === 1 ? "" : "s"} without a nearby notice (consider adding).`, [...new Set(cases.map(({ p }) => p.evidenceKey + "_forms"))])],
  };
}
