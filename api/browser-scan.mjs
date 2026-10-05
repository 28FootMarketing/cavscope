// CavScope browser engine, hosted as a Vercel function. Chromium cannot run in a Supabase edge function;
// this can, so the engine in workers/browser-scan/ runs here.
//
// Called by the database (pg_net) with the shared secret when a browser scan is requested, and by a
// five-minute sweep for scans whose kick never arrived:
//
//   POST /api/browser-scan            x-cavscope-worker-secret: <secret>
//   { "scan_id": 123 }                run that queued scan
//   {}                                run the oldest queued browser scan
//
// It answers 202 at once and does the scan after the response (waitUntil), so the caller never waits on a
// browser. The secret is checked here and again in the database, which is what actually decides what this
// function may touch: it holds the anon key and one shared secret, never a service-role key.

import { timingSafeEqual } from "node:crypto";
import { waitUntil } from "@vercel/functions";
import { dispatch, makeRpc } from "../workers/browser-scan/lib/job.mjs";

const SUPABASE_URL = process.env.CAVSCOPE_SUPABASE_URL ?? "https://hjowfnzpomzxazmzywxw.supabase.co";
// The publishable key ships in every page's source; it is not a secret.
const ANON_KEY = process.env.CAVSCOPE_SUPABASE_ANON_KEY ?? "sb_publishable_VvbvcqDMSTBriHmIMmmvpg_Een-yuWL";

const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

export function secretMatches(given, expected) {
  if (!expected || typeof given !== "string") return false;
  const a = Buffer.from(given), b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

// `deps` exists so the handler can be tested without Chromium, a database or a deadline.
export async function handle(request, deps = {}) {
  if (request.method !== "POST") return json({ error: "POST only" }, 405);
  const expected = deps.secret ?? process.env.CAVSCOPE_BROWSER_WORKER_SECRET;
  if (!expected) return json({ error: "worker is not configured" }, 503);
  if (!secretMatches(request.headers.get("x-cavscope-worker-secret"), expected)) return json({ error: "forbidden" }, 401);

  let body = {};
  try { body = await request.json(); } catch { /* an empty body means: oldest queued */ }
  const scanId = Number.isInteger(body?.scan_id) ? body.scan_id : null;

  const rpc = deps.rpc ?? makeRpc({ url: SUPABASE_URL, anonKey: ANON_KEY, secret: expected });
  const run = deps.run ?? (async (args) => (await import("../workers/browser-scan/lib/hosted.mjs")).runHosted(args));
  const work = dispatch({ rpc, scanId, limit: 1, run, log: deps.log ?? ((m) => console.log(m)) })
    .catch((e) => console.error("browser-scan dispatch failed:", e?.message ?? e));
  (deps.waitUntil ?? waitUntil)(work);
  return json({ accepted: true, scan_id: scanId }, 202);
}

export async function POST(request) { return handle(request); }
// No GET: a request that carries a secret in a header is never a link someone should be able to click.
