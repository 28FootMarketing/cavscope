// The SITREP's Laws and Standards section must never turn "not looked at" into "passed".
//
//   node --experimental-strip-types --test tests/sitrep/jurisdiction.test.ts
//
// muster.q_sitrep_jurisdiction was computed on every report since migration 046 and
// rendered nowhere. When migration 082 rendered it, the payload's `status` could not
// be printed as-is: `clear` means "no open finding on a mapped rule", and for the
// YMCA six of thirteen laws (CAN-SPAM, TCPA, C2PA, ISO 42001, the OECD principles,
// PA Act 35) map to no rule at all. "CAN-SPAM: clear" on a scan that cannot look at
// email marketing is absence of findings read as a pass, in the section most likely
// to be read as legal comfort.
//
// So 082 assigns each law an `assessment` in SQL and stores it, and both renderers
// read that field. This file pins the SQL rules, and runs the viewer's real
// renderJurisdiction, extracted from sitrep.html, against fixture payloads.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const migrationsDir = join(repoRoot, "supabase", "migrations");

const newestDefining = (re: RegExp) => {
  const files = readdirSync(migrationsDir).filter((f) => f.endsWith(".sql"))
    .filter((f) => re.test(readFileSync(join(migrationsDir, f), "utf8"))).sort();
  assert.ok(files.length, `no migration matches ${re}`);
  return readFileSync(join(migrationsDir, files[files.length - 1]), "utf8");
};

const assessSql = (() => {
  const sql = newestDefining(/create or replace function muster\.sitrep_jurisdiction_assess/i);
  const at = sql.indexOf("create or replace function muster.sitrep_jurisdiction_assess");
  return sql.slice(at, sql.indexOf("$function$;", at));
})();
const mdSql = (() => {
  const sql = newestDefining(/create or replace function muster\.sitrep_jurisdiction_md/i);
  const at = sql.indexOf("create or replace function muster.sitrep_jurisdiction_md");
  return sql.slice(at, sql.indexOf("$function$;", at));
})();
const generatorSql = (() => {
  const sql = newestDefining(/create or replace function muster\.generate_sitrep/i);
  const at = sql.indexOf("create or replace function muster.generate_sitrep");
  return sql.slice(at, sql.indexOf("$function$;", at));
})();

// --- the SQL decides, once ----------------------------------------------------

test("a law with no mapped check is not_assessed, whatever its status says", () => {
  // The order of the CASE arms is the rule: open findings first, then "no mapped
  // check", then "unread scan", and only then a pass.
  const arms = assessSql.slice(assessSql.indexOf("'assessment'"), assessSql.indexOf("'not_assessed_reason'"));
  const iOpen = arms.indexOf("in ('exposed', 'attention') then 'open_findings'");
  const iNoCheck = arms.indexOf("= 0 then 'not_assessed'");
  const iUnread = arms.indexOf("when p_unread then 'not_assessed'");
  const iPass = arms.indexOf("else 'no_open_findings'");
  assert.ok(iOpen > 0 && iNoCheck > iOpen && iUnread > iNoCheck && iPass > iUnread, "assessment arms are out of order");
});

test("an unavailable payload is passed through, not assessed into an empty list", () => {
  assert.match(assessSql, /is not true then p_jur/);
});

test("the markdown leads with the disclaimer and never calls a mapped pass compliance", () => {
  assert.match(mdSql, /## Laws and Standards/);
  assert.match(mdSql, /p_jur->>'disclaimer'/);
  assert.match(mdSql, /### Open findings touch these/);
  assert.match(mdSql, /### No open findings on the mapped checks/);
  assert.match(mdSql, /### Not assessed by this scan/);
  assert.match(mdSql, /That is not a determination of compliance/);
  assert.match(mdSql, /It is not a finding that the law was breached/);
  assert.match(mdSql, /Applies when: %s/);
  // The one word that would undo all of this.
  assert.doesNotMatch(mdSql, /\bclear\b/i);
});

test("the generator assesses once, stores the assessed payload, and renders before the Evidence Index", () => {
  assert.match(generatorSql, /v_jur := muster\.sitrep_jurisdiction_assess\(muster\.q_sitrep_jurisdiction\(v\.website_id\), coalesce\(v_unread, false\)\)/);
  assert.match(generatorSql, /'jurisdiction', v_jur,/);
  assert.doesNotMatch(generatorSql, /'jurisdiction', muster\.q_sitrep_jurisdiction/);
  const iMd = generatorSql.indexOf("muster.sitrep_jurisdiction_md(v_jur)");
  assert.ok(iMd > generatorSql.indexOf("## Plain English") && iMd < generatorSql.indexOf("## Evidence Index"));
});

// --- the viewer reads the same field ------------------------------------------

const html = readFileSync(join(repoRoot, "sitrep.html"), "utf8");
const fnSrc = html.slice(html.indexOf("  function renderJurisdiction(j) {"), html.indexOf("  // end renderJurisdiction"));
const escAt = html.indexOf("  function escapeHtml(str) {");
const escSrc = html.slice(escAt, html.indexOf("\n  }\n", escAt) + 4);
// deno-lint-ignore no-explicit-any
const renderJurisdiction = new Function(`${escSrc}\n${fnSrc}\nreturn renderJurisdiction;`)() as (j: any) => string;

const law = (o: Record<string, unknown>) => ({
  short_name: "X", jurisdiction_code: "US", summary: "", applies_when: "Always.", rule_ids: [], open_findings: [],
  reference_url: "https://example.gov/", ...o,
});
const payload = (laws: unknown[], extra: Record<string, unknown> = {}) => ({
  available: true, disclaimer: "Informational only. MUSTER is not a law firm and this is not legal advice. Confirm applicability with counsel.",
  region_code: "US-PA", country_code: "US",
  jurisdictions: [{ code: "US", kind: "country", name: "United States" }, { code: "US-PA", kind: "region", name: "Pennsylvania" }],
  laws, ...extra,
});
// Shaped from the YMCA's real payload (website 11, 2026-09-23).
const YMCA = payload([
  law({ short_name: "ADA Title III", status: "attention", assessment: "open_findings", rule_ids: ["A11Y-007"],
        applies_when: "Any business open to the public with a website.",
        open_findings: [{ finding_id: 309, rule_id: "A11Y-007", severity: "medium", title: "Links with no discernible text" }] }),
  law({ short_name: "FTC Act Section 5", status: "clear", assessment: "no_open_findings", rule_ids: ["PRIV-001", "SEC-001", "SEC-013"] }),
  law({ short_name: "CAN-SPAM", status: "clear", assessment: "not_assessed", not_assessed_reason: "no_mapped_check",
        applies_when: "Any commercial email." }),
]);

const between = (out: string, a: string, b?: string) => out.slice(out.indexOf(a), b ? out.indexOf(b) : undefined);

test("the viewer buckets by assessment: CAN-SPAM under Not assessed, FTC under the mapped heading", () => {
  const out = renderJurisdiction(YMCA);
  const na = between(out, "Not assessed by this scan");
  const mapped = between(out, "No open findings on the mapped checks", "Not assessed by this scan");
  const open = between(out, "Open findings touch these", "No open findings on the mapped checks");
  assert.match(na, /CAN-SPAM/);
  assert.match(na, /No MUSTER check maps to it\./);
  assert.match(mapped, /FTC Act Section 5/);
  assert.doesNotMatch(mapped, /CAN-SPAM/);
  assert.match(open, /ADA Title III/);
  assert.match(open, /\[F309\]/);
  assert.match(out, /Applies when:<\/span> Any business open to the public/);
  assert.match(out, /MUSTER is not a law firm and this is not legal advice/);
  assert.match(out, /not a determination of compliance/);
  assert.match(out, /Location on record: Pennsylvania, United States\./);
});

test("the viewer never shows the raw status word as a verdict", () => {
  const out = renderJurisdiction(YMCA).replace(/<[^>]*>/g, " ");
  assert.doesNotMatch(out, /\bclear\b/i);
  assert.doesNotMatch(out, /\bcompliant\b/i);
});

test("a report generated before 082 says so rather than guessing a bucket from status", () => {
  const old = payload([law({ short_name: "CAN-SPAM", status: "clear" })]);
  const out = renderJurisdiction(old);
  assert.match(out, /generated before laws were assessed/);
  assert.doesNotMatch(out, /No open findings on the mapped checks/);
  assert.doesNotMatch(out, /CAN-SPAM/);
});

test("an unread scan says why its laws are not assessed", () => {
  const out = renderJurisdiction(payload([
    law({ short_name: "HTTPS baseline", status: "clear", assessment: "not_assessed", not_assessed_reason: "scan_unread", rule_ids: ["SEC-001"] }),
  ], { scan_unread: true }));
  assert.match(out, /did not read the page/);
  assert.match(out, /Its checks could not run on this scan\./);
  assert.doesNotMatch(out, /No open findings on the mapped checks/);
});

test("no jurisdiction on record shows the reason, not an empty list", () => {
  const out = renderJurisdiction({ available: false, reason: "No country recorded for this organization, so no jurisdiction advisory can be given." });
  assert.match(out, /No country recorded for this organization/);
});

test("catalogue text is escaped and only https references become links", () => {
  const out = renderJurisdiction(payload([
    law({ short_name: "<img src=x onerror=alert(1)>", assessment: "not_assessed", not_assessed_reason: "no_mapped_check",
          reference_url: "javascript:alert(1)" }),
  ]));
  assert.doesNotMatch(out, /<img src=x/);
  assert.match(out, /&lt;img src=x onerror=alert\(1\)&gt;/);
  assert.doesNotMatch(out, /href="javascript:/);
});

test("the viewer renders the scope note after the Board Report and the laws before the Evidence Index", () => {
  const body = html.slice(html.indexOf("function renderSitrep(sitrep)"), html.indexOf("function citeBadge(claim)"));
  const iBoard = body.indexOf(">Board Report</h2>");
  const iScope = body.indexOf(">What This Scan Did Not Check</h2>");
  const iLaws = body.indexOf("${renderJurisdiction(s.jurisdiction)}");
  const iEvidence = body.indexOf(">Evidence Index</h2>");
  assert.ok(iBoard > 0 && iScope > iBoard, "scope note must follow the Board Report");
  assert.ok(iLaws > iScope && iEvidence > iLaws, "laws must precede the Evidence Index");
});
