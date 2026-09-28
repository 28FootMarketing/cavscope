/**
 * Run the CavScope scan engine against a URL from a terminal, with no database.
 *
 *   node --experimental-strip-types tools/local-scan/run.mjs https://example.com
 *   node --experimental-strip-types tools/local-scan/run.mjs https://example.com --json out.json
 *
 * WHAT THIS IS FOR
 *
 * The real path to a scan is the deployed engine: it claims a queued scan,
 * ingests evidence and findings through muster_engine_ingest, and generates a
 * SITREP. That needs the service-role key and a tenant. This runs the same rule
 * code with neither, which is what you want when you are triaging a site you do
 * not want in a tenant's risk register, when you have no key to hand, or from CI.
 *
 * WHAT IT IS NOT
 *
 * It writes nothing to the database, opens no incident, emails no alert, and
 * produces no SITREP narrative -- that is generated in Postgres and by
 * muster-agent, not here. It reports findings, evidence and a posture score.
 *
 * NETWORK
 *
 * Node's built-in fetch ignores HTTPS_PROXY. Behind a proxy, run with
 * NODE_USE_ENV_PROXY=1 (Node >= 22.21) or the scan reports the whole site
 * unreachable. The engine resolves SPF and DMARC over DNS-over-HTTPS against
 * dns.google with a Cloudflare fallback, so both must be reachable or the
 * EMAIL-* family correctly reports nothing at all.
 */

import { writeFile } from "node:fs/promises";
import { loadEngine } from "./adapt.mjs";
import { postureScore, postureBand, countBySeverity, SEVERITY_ORDER } from "./score.mjs";

const args = process.argv.slice(2);
const target = args.find((a) => !a.startsWith("--"));
const jsonAt = args.indexOf("--json");
const jsonPath = jsonAt === -1 ? null : args[jsonAt + 1];

if (!target) {
  console.error("usage: node --experimental-strip-types tools/local-scan/run.mjs <url> [--json <path>]");
  process.exit(2);
}

let url;
try {
  url = new URL(/^https?:\/\//i.test(target) ? target : `https://${target}`);
} catch {
  console.error(`not a URL: ${target}`);
  process.exit(2);
}

const engine = await import(await loadEngine()).catch((e) => {
  console.error("failed to load the adapted engine. On Node < 22.18 pass --experimental-strip-types.\n" + String(e));
  process.exit(1);
});

if (!process.env.NODE_USE_ENV_PROXY && (process.env.HTTPS_PROXY || process.env.https_proxy)) {
  console.error("warning: HTTPS_PROXY is set but NODE_USE_ENV_PROXY is not. fetch() will bypass the proxy and every check may report unreachable.\n");
}

const started = Date.now();
const result = await engine.runScan({
  scan_id: 0,
  website_id: 0,
  target_url: url.href,
  website_name: url.hostname,
});

const findings = result.findings;
const score = postureScore(findings);
const band = postureBand(score);
const counts = countBySeverity(findings);

const pad = (s, n) => String(s).padEnd(n);
console.log(`CavScope local scan  engine ${engine.ENGINE_VERSION}`);
console.log(`target       ${url.href}`);
console.log(`final url    ${result.final_url}`);
console.log(`http         ${result.scan.http_status ?? "no response"}  ${result.scan.response_ms} ms`);
console.log(`posture      ${score}/100 (${band})`);
console.log(`findings     ${findings.length}   ` + SEVERITY_ORDER.map((s) => `${s} ${counts[s]}`).join("  "));
console.log(`evidence     ${result.evidence.length} artefacts`);
console.log(`elapsed      ${Date.now() - started} ms`);
console.log("");

const rank = (f) => SEVERITY_ORDER.indexOf(f.severity);
for (const f of [...findings].sort((a, b) => rank(a) - rank(b) || a.rule_id.localeCompare(b.rule_id))) {
  console.log(`${pad(f.severity.toUpperCase(), 9)} ${pad(f.rule_id, 10)} ${f.title}`);
  console.log(`${" ".repeat(20)}${f.detail}`);
  console.log(`${" ".repeat(20)}at ${f.location ?? "-"}  confidence ${f.confidence}  evidence ${f.evidence_keys.join(", ")}`);
  console.log("");
}

if (!findings.length) console.log("No findings. Every active rule passed.\n");

if (jsonPath) {
  await writeFile(jsonPath, JSON.stringify({
    engine: engine.ENGINE_VERSION,
    scanned_at: new Date().toISOString(),
    target: url.href,
    scan: result.scan,
    posture: { score, band, counts },
    findings,
    evidence: result.evidence,
  }, null, 2) + "\n", "utf8");
  console.log(`wrote ${jsonPath}`);
}

// A critical or high finding is what opens an alert in the product; make that
// visible to CI without having to parse the output.
process.exit(counts.critical || counts.high ? 1 : 0);
