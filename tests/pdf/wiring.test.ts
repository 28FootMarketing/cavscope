// The PDF export is reachable only through the checks that guard it.
//
//   node --experimental-strip-types --test tests/pdf/wiring.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(root, p), "utf8");
const fn = read("supabase/functions/cavscope-sitrep-pdf/index.ts");
const sitrep = read("sitrep.html");
const migDir = join(root, "supabase", "migrations");
const mig = (needle: string) => readdirSync(migDir).filter((f) => f.includes(needle)).map((f) => readFileSync(join(migDir, f), "utf8")).join("\n");

test("the function checks the flag in Postgres before it reads the report", () => {
  const allowed = fn.indexOf('"cavscope_pdf_export_allowed"');
  const report = fn.indexOf('"cavscope_sitrep"');
  assert.ok(allowed > 0 && report > 0, "both calls present");
  assert.ok(allowed < report, "access is decided before the report is fetched");
  assert.match(fn, /allowed\.data !== true\) return json\(\{ error: "PDF export is not enabled for this report" \}, 403\)/);
});

test("the function needs a bearer token, POST, and a whole-number id", () => {
  assert.match(fn, /req\.method !== "POST"\) return json\(\{ error: "POST only" \}, 405\)/);
  assert.match(fn, /startsWith\("bearer "\)\) return json\(\{ error: "sign in first" \}, 401\)/);
  assert.match(fn, /Number\.isSafeInteger\(id\) \|\| id <= 0/);
});

test("it runs as the caller, never with the service role, and stores nothing", () => {
  assert.doesNotMatch(fn, /SERVICE_ROLE/);
  assert.match(fn, /global: \{ headers: \{ Authorization: auth \} \}/);
  const code = fn.split("\n").filter((l) => !l.trimStart().startsWith("//")).join("\n");
  assert.doesNotMatch(code, /\.from\(|\.storage|console\./);
});

test("the gateway verifies the JWT and the import map names pdf-lib", () => {
  assert.match(read("supabase/config.toml"), /\[functions\.cavscope-sitrep-pdf\][^[]*verify_jwt = true/);
  assert.match(read("supabase/functions/cavscope-sitrep-pdf/deno.json"), /"pdf-lib": "npm:pdf-lib@1\.17\.1"/);
});

test("the access check honours the kill switch, membership and the flag, and anon cannot call it", () => {
  const sql = mig("pdf_export_allowed");
  assert.match(sql, /key = 'pdf_export' and kill_switch/);
  assert.match(sql, /is_org_member\(v_org\)/);
  assert.match(sql, /has_flag\(v_org, 'pdf_export'\)/);
  assert.match(sql, /revoke all on function public\.cavscope_pdf_export_allowed\(bigint\) from public, anon/);
});

test("the viewer's button is hidden until the database says yes", () => {
  assert.match(sitrep, /id="btnDownloadPdf" hidden/);
  assert.match(sitrep, /rpc\('cavscope_pdf_export_allowed'/);
  assert.match(sitrep, /if \(ok === true && currentSitrepId === sitrepId\) btn\.hidden = false/);
  assert.match(sitrep, /renderEmpty\(title, body\) \{\s*const pdfBtn[\s\S]{0,120}pdfBtn\.hidden = true/);
});
