import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  applyFixes, audit, FIXES, isFetchableScriptUrl, LANGUAGES, MAX_HTML_BYTES, NOT_CHECKED, sriCandidates, sriFor,
  type Choices,
} from "./fixes.ts";

// The HTML audit. A signed-in caller posts a page's HTML; this runs the scan
// engine's own page rules on it (cavscope-scan/page-checks.ts, shared, not
// copied) and, on request, applies the fixes the caller chose and returns the
// corrected HTML. For a one-off site CavScope does not scan.
//
// Who may call it is decided in Postgres, by public.cavscope_html_audit_allowed()
// under the caller's own JWT: super admins, plus members of any workspace the
// html_audit flag is turned on for. That check runs before the HTML is parsed.
//
// Nothing is stored. The HTML may be a client's page that is not yet public, so
// it lives only for the length of the request: no table, no log line with its
// content, no activity event carrying it.
//
// The one outbound request is for SEC-014: to pin a third-party script with an
// integrity hash, the hash has to be of the script's actual bytes, so the
// function fetches each script the caller ticked. Those addresses come from
// pasted HTML, so each must be one the page itself names as an SRI candidate,
// https on a public DNS name (isFetchableScriptUrl), no redirects, 5 seconds,
// 2 MB, at most 20 per request. A script that fails any of that is reported
// back and left unpinned, never guessed at.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const MAX_SRI_SCRIPTS = 20;
const MAX_SCRIPT_BYTES = 2_000_000;
const SCRIPT_TIMEOUT_MS = 5000;

type SriFailure = { src: string; reason: string };

async function fetchScript(url: string): Promise<Uint8Array | string> {
  if (!isFetchableScriptUrl(url)) return "not a public https address";
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), SCRIPT_TIMEOUT_MS);
  try {
    const res = await fetch(url, { redirect: "manual", signal: ctrl.signal, headers: { accept: "*/*" } });
    if (res.status >= 300 && res.status < 400) {
      await res.body?.cancel();
      return "the address redirects, so the file it serves can change; pin the final address instead";
    }
    if (!res.ok || !res.body) {
      await res.body?.cancel();
      return `the server answered ${res.status}`;
    }
    const reader = res.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_SCRIPT_BYTES) { await reader.cancel(); return "larger than 2 MB"; }
      chunks.push(value);
    }
    const out = new Uint8Array(size);
    let at = 0;
    for (const c of chunks) { out.set(c, at); at += c.byteLength; }
    return out;
  } catch (e) {
    return ctrl.signal.aborted ? "timed out after 5 seconds" : `could not be fetched (${String((e as Error)?.name ?? "error")})`;
  } finally {
    clearTimeout(t);
  }
}

async function hashChosen(html: string, pageUrl: string | null, chosen: unknown): Promise<{ sri: Record<string, string>; failures: SriFailure[] }> {
  const sri: Record<string, string> = {};
  const failures: SriFailure[] = [];
  if (!Array.isArray(chosen) || chosen.length === 0) return { sri, failures };
  const bySrc = new Map(sriCandidates(html, pageUrl).map((c) => [c.src, c]));
  const picked = [...new Set(chosen.filter((s): s is string => typeof s === "string"))].slice(0, MAX_SRI_SCRIPTS);
  await Promise.all(picked.map(async (src) => {
    const c = bySrc.get(src);
    if (!c) { failures.push({ src, reason: "not an unpinned third-party script on this page" }); return; }
    const got = await fetchScript(c.url);
    if (typeof got === "string") failures.push({ src, reason: got });
    else sri[src] = await sriFor(got);
  }));
  return { sri, failures };
}

function describe(html: string, pageUrl: string | null) {
  const a = audit(html, pageUrl);
  return {
    findings: a.findings.map((f) => ({ ...f, fix: FIXES[f.rule_id] ?? null })),
    targets: a.targets,
    sri_candidates: sriCandidates(html, pageUrl),
    client_rendered: a.clientRendered,
    context: a.context,
    not_checked: NOT_CHECKED,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const authorization = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(authorization)) return json({ error: "sign in first" }, 401);
  const db = createClient(URL_, ANON, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: allowed, error: gateError } = await db.rpc("cavscope_html_audit_allowed");
  // 42501 is the anon role reaching a gate it has no grant on (a publishable
  // key presented as the bearer): a refusal, not a fault, so it answers 403 like
  // any other caller the gate says no to. Anything else is a real failure.
  if (gateError && gateError.code !== "42501") return json({ error: "could not confirm access" }, 502);
  if (gateError || allowed !== true) return json({ error: "The HTML audit is not turned on for your account." }, 403);

  const declared = Number(req.headers.get("content-length") ?? "0");
  const limit = MAX_HTML_BYTES * 2 + 200_000; // JSON escaping can double the HTML
  if (declared > limit) return json({ error: "The HTML is larger than 2 MB." }, 413);
  const raw = await req.text();
  if (raw.length > limit) return json({ error: "The HTML is larger than 2 MB." }, 413);

  let body: { action?: string; html?: unknown; page_url?: unknown; choices?: unknown; pin_scripts?: unknown };
  try { body = JSON.parse(raw); } catch { return json({ error: "invalid JSON body" }, 400); }
  const html = typeof body.html === "string" ? body.html : "";
  if (!html.trim()) return json({ error: "Paste the page's HTML first." }, 400);
  if (new TextEncoder().encode(html).byteLength > MAX_HTML_BYTES) return json({ error: "The HTML is larger than 2 MB." }, 413);
  const pageUrl = typeof body.page_url === "string" && body.page_url.trim() ? body.page_url.trim() : null;

  if (body.action === "audit") {
    return json({ ...describe(html, pageUrl), languages: LANGUAGES });
  }

  if (body.action === "fix") {
    const choices = (body.choices && typeof body.choices === "object" ? body.choices : {}) as Choices;
    const { sri, failures } = await hashChosen(html, pageUrl, body.pin_scripts);
    const fixed = applyFixes(html, pageUrl, { ...choices, sri });
    return json({ html: fixed.html, changes: fixed.changes, sri_failures: failures, after: describe(fixed.html, pageUrl) });
  }

  return json({ error: "action must be audit or fix" }, 400);
});
