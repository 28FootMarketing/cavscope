// Run the browser engine against a URL with no database: prints findings and every check result.
//   node cli.mjs https://www.aftertoday.agency [--cache-bust] [--wait-for="marker text"] [--json]
// Writes nothing anywhere. Use it for triage and for fixtures; the worker is what records a scan.
import { runBrowserScan } from "./lib/engine.mjs";

const args = process.argv.slice(2);
const url = args.find((a) => /^https?:\/\//.test(a));
if (!url) { console.error("usage: node cli.mjs <url> [--cache-bust]"); process.exit(2); }
const waitFor = args.find((a) => a.startsWith("--wait-for="))?.slice("--wait-for=".length);
const out = await runBrowserScan({ targetUrl: url, options: { cache_bust: args.includes("--cache-bust"), wait_for: waitFor ? { marker: waitFor } : undefined } });
console.log(`${out.scan.engine_version}: ${out.scan.pages_visited} pages, ${out.evidence.length} evidence rows, ${out.findings.length} findings`);
for (const c of out.scan.browser_checks) console.log(`  ${c.rule_id.padEnd(9)} ${c.outcome.padEnd(14)} ${c.detail}`);
for (const f of out.findings) console.log(`  [${f.severity}] ${f.rule_id} ${f.title} -- ${f.detail.slice(0, 160)}`);
if (args.includes("--json")) console.log(JSON.stringify(out, null, 2));
process.exit(out.findings.some((f) => f.severity === "high" || f.severity === "critical") ? 1 : 0);
