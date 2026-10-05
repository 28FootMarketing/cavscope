// The Vercel function that hosts the browser engine, and the job module under it. No Chromium, no database.
//   node --experimental-strip-types --test tests/browser/api.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
// @ts-ignore
import { handle, secretMatches } from "../../api/browser-scan.mjs";
// @ts-ignore
import { dispatch, makeRpc, processScan } from "../../workers/browser-scan/lib/job.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SECRET = "s3cret-value-for-tests";
const req = (method = "POST", headers: Record<string, string> = {}, body?: unknown) =>
  new Request("https://cavscope.28footsystems.com/api/browser-scan", { method, headers: { "content-type": "application/json", ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });

test("the function refuses everything without the secret, and never touches the database or a browser", async () => {
  let touched = 0;
  const deps = { secret: SECRET, rpc: async () => { touched++; return []; }, run: async () => { touched++; }, waitUntil: () => { touched++; } };
  assert.equal((await handle(req("GET"), deps)).status, 405);
  assert.equal((await handle(req("POST"), deps)).status, 401, "no header");
  assert.equal((await handle(req("POST", { "x-cavscope-worker-secret": "wrong" }), deps)).status, 401);
  assert.equal((await handle(req("POST", { "x-cavscope-worker-secret": SECRET + "x" }), deps)).status, 401, "a longer value is not a match");
  assert.equal((await handle(req("POST", { "x-cavscope-worker-secret": SECRET }), { ...deps, secret: "" })).status, 503, "an unconfigured function does not run anything");
  assert.equal(touched, 0);
});

test("a valid call answers 202 immediately and does the scan after the response", async () => {
  let started = false; let finish!: () => void; const gate = new Promise<void>((r) => (finish = r));
  const calls: string[] = [];
  const rpc = async (name: string, args: any) => {
    calls.push(name);
    if (name === "cavscope_worker_claim_browser") { assert.equal(args.p_scan_id, 42); return [{ scan_id: 42, website_id: 7, target_url: "https://x.test/", options: {}, verified: false, endpoint_hosts: [] }]; }
    if (name === "cavscope_worker_open_findings") return [];
    if (name === "cavscope_worker_ingest") return { scan_id: 42 };
    return null;
  };
  let waited: Promise<unknown> | null = null;
  const res = await handle(req("POST", { "x-cavscope-worker-secret": SECRET }, { scan_id: 42 }), {
    secret: SECRET, rpc, log: () => {}, waitUntil: (p: Promise<unknown>) => { waited = p; },
    run: async () => { started = true; await gate; return { scan: { engine_version: "browser-1.0.0" }, evidence: [], findings: [] }; },
  });
  assert.equal(res.status, 202);
  assert.deepEqual(await res.json(), { accepted: true, scan_id: 42 });
  assert.ok(waited, "work was handed to waitUntil, not awaited in the response");
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(started, true);
  finish(); await waited;
  assert.deepEqual(calls, ["cavscope_worker_claim_browser", "cavscope_worker_open_findings", "cavscope_worker_ingest"]);
});

test("secret comparison is exact and length-safe", () => {
  assert.equal(secretMatches("abc", "abc"), true);
  assert.equal(secretMatches("abc", "abd"), false);
  assert.equal(secretMatches("ab", "abc"), false);
  assert.equal(secretMatches(null, "abc"), false);
  assert.equal(secretMatches("abc", ""), false);
});

test("a scan that throws is failed through the database, not left running", async () => {
  const calls: any[] = [];
  const rpc = async (name: string, args: any) => { calls.push([name, args]); if (name === "cavscope_worker_open_findings") return []; return null; };
  const r = await processScan({ rpc, job: { scan_id: 9, website_id: 1, target_url: "https://x.test/" }, run: async () => { throw new Error("navigation timeout"); }, log: () => {} });
  assert.equal(r.ok, false);
  const fail = calls.find((c) => c[0] === "cavscope_worker_fail");
  assert.equal(fail[1].p_scan_id, 9);
  assert.match(fail[1].p_error, /^browser engine: navigation timeout/);
});

test("previous browser findings reach the engine as RULE|location keys, and the claim's authorization context reaches its options", async () => {
  let seen: any;
  const rpc = async (name: string) => (name === "cavscope_worker_open_findings" ? [{ rule_id: "A11Y-008", location: "image-alt" }] : { ok: 1 });
  await processScan({ rpc, job: { scan_id: 1, website_id: 2, target_url: "https://x.test/", options: { active_tests: true, authorization_id: 5 }, verified: true, endpoint_hosts: ["abc.supabase.co"] }, log: () => {},
    run: async (a: any) => { seen = a; return { scan: {}, evidence: [], findings: [] }; } });
  assert.deepEqual([...seen.previousKeys], ["A11Y-008|image-alt"]);
  assert.equal(seen.options.verified, true);
  assert.deepEqual(seen.options.endpoint_hosts, ["abc.supabase.co"]);
  assert.equal(seen.options.authorization_id, 5);
});

test("an unreachable previous-findings read does not stop the scan", async () => {
  const rpc = async (name: string) => { if (name === "cavscope_worker_open_findings") throw new Error("boom"); return { ok: 1 }; };
  const r = await processScan({ rpc, job: { scan_id: 1, website_id: 2, target_url: "https://x.test/" }, log: () => {}, run: async () => ({ scan: {}, evidence: [], findings: [] }) });
  assert.equal(r.ok, true);
});

test("the RPC client sends the shared secret in the body, the anon key as the key, and surfaces a refusal", async () => {
  let call: any;
  const fetchImpl = async (url: string, init: any) => { call = { url, init }; return { ok: true, text: async () => "[]" }; };
  const rpc = makeRpc({ url: "https://p.supabase.co", anonKey: "ANON", secret: "SEC", fetchImpl });
  await rpc("cavscope_worker_claim_browser", { p_scan_id: 3 });
  assert.equal(call.url, "https://p.supabase.co/rest/v1/rpc/cavscope_worker_claim_browser");
  assert.equal(call.init.headers.apikey, "ANON");
  assert.deepEqual(JSON.parse(call.init.body), { p_secret: "SEC", p_scan_id: 3 });
  const refuse = makeRpc({ url: "u", anonKey: "A", secret: "S", fetchImpl: async () => ({ ok: false, status: 401, text: async () => '{"message":"forbidden"}' }) });
  await assert.rejects(() => refuse("x"), /x 401: .*forbidden/);
  assert.equal((await dispatch({ rpc: async () => [], run: async () => null })).claimed, 0);
});

test("the function holds no service-role key and the hosted runner is loaded lazily", () => {
  const src = readFileSync(join(root, "api", "browser-scan.mjs"), "utf8");
  assert.ok(!/service_role|SERVICE_ROLE/i.test(src.replace(/\/\/.*$/gm, "")), "no service-role key is read");
  assert.match(src, /await import\("\.\.\/workers\/browser-scan\/lib\/hosted\.mjs"\)/);
  assert.ok(!/export (async )?function GET/.test(src), "no GET handler: a secret in a header is never a clickable link");
});

test("deployment config: functions only, no routing, 300 s, chromium's binaries included; pins match the worker's", () => {
  const v = JSON.parse(readFileSync(join(root, "vercel.json"), "utf8"));
  assert.deepEqual(Object.keys(v), ["functions"], "vercel.json carries no rewrites, routes, redirects or headers: routing lives in middleware.js");
  assert.equal(v.functions["api/browser-scan.mjs"].maxDuration, 300);
  assert.match(v.functions["api/browser-scan.mjs"].includeFiles, /@sparticuz\/chromium\/bin/);
  const rootPkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  const workerPkg = JSON.parse(readFileSync(join(root, "workers/browser-scan/package.json"), "utf8"));
  for (const d of ["playwright-core", "axe-core"]) assert.equal(rootPkg.dependencies[d], workerPkg.dependencies[d], `${d} is pinned to one version in both`);
  assert.equal(rootPkg.dependencies["@sparticuz/chromium"].split(".")[0], "141", "Chromium major matches playwright-core 1.56 (Chromium 141)");
});
