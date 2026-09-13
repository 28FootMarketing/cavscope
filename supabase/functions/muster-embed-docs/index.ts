import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Embeds MUSTER's own documentation so the agent can search it (muster_047/048).
//
// Split of responsibility, on purpose: the caller (tools/embed-docs/sync.ts) reads
// the repository and does the chunking, which needs no credential at all; this
// function holds the OpenRouter key and the database write. So the sync tool can
// run from a laptop or CI with nothing but the shared secret, and the inference
// credential never leaves the edge runtime.
//
// It is idempotent by content hash. Every chunk arrives with a sha256 of its text;
// a chunk whose stored hash matches is skipped without an embedding call, so
// re-running the sync against unchanged docs costs zero credit and zero writes.
//
// POST { "documents": [ { doc_path, doc_title, visibility, chunks: [ { heading,
//        anchor, chunk_index, text, sha, token_estimate } ] } ], "dry_run": false }
// Header: x-muster-secret
//
// verify_jwt is false, so the shared-secret check below is the only thing between
// this and an open endpoint that spends credit and rewrites what the agent reads.

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function openRouterKey(): string | undefined {
  return Deno.env.get("MUSTER_OPENROUTER_API_KEY") ?? Deno.env.get("OPENROUTER_API_KEY");
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

/** Constant-time compare, so a wrong secret leaks nothing about how wrong it was. */
function secretMatches(provided: string, expected: string): boolean {
  const a = new TextEncoder().encode(provided);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

// Conditions that will fail identically on every remaining chunk: a missing key, a
// rejected key, an exhausted credit limit. Abort the run rather than burn one
// request per chunk against a dead key.
class FatalEmbedError extends Error {}

async function embedText(text: string): Promise<number[]> {
  const apiKey = openRouterKey();
  if (!apiKey) throw new FatalEmbedError("neither MUSTER_OPENROUTER_API_KEY nor OPENROUTER_API_KEY is set");

  const res = await fetch("https://openrouter.ai/api/v1/embeddings", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "authorization": `Bearer ${apiKey}`,
      "http-referer": "https://muster.partners",
      "x-title": "MUSTER doc embedding",
    },
    body: JSON.stringify({ model: "openai/text-embedding-3-small", input: text, encoding_format: "float" }),
    signal: AbortSignal.timeout(15000),
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    const message = `embedding failed (${res.status}): ${detail.slice(0, 300)}`;
    if ([401, 402, 403, 429].includes(res.status)) throw new FatalEmbedError(message);
    throw new Error(message);
  }

  const payload = await res.json();
  const embedding = payload?.data?.[0]?.embedding;
  if (!Array.isArray(embedding) || embedding.length === 0) throw new Error("embedding returned no vector");
  return embedding;
}

type IncomingChunk = {
  heading?: string; anchor?: string; chunk_index?: number;
  text?: string; sha?: string; token_estimate?: number;
};
type IncomingDoc = {
  doc_path?: string; doc_title?: string; visibility?: string; chunks?: IncomingChunk[];
};

/**
 * Reject a malformed document before writing any part of it. A document that is
 * half-written is worse than one that is not written at all: the agent still finds
 * chunks, cites them, and nothing signals that the other half is missing.
 */
function validateDoc(doc: IncomingDoc): string | null {
  if (!doc.doc_path || typeof doc.doc_path !== "string") return "doc_path is required";
  if (!doc.doc_title || typeof doc.doc_title !== "string") return `${doc.doc_path}: doc_title is required`;
  if (doc.visibility !== "public" && doc.visibility !== "internal") {
    return `${doc.doc_path}: visibility must be "public" or "internal", got ${JSON.stringify(doc.visibility)}`;
  }
  if (!Array.isArray(doc.chunks) || doc.chunks.length === 0) return `${doc.doc_path}: chunks is required and must be non-empty`;

  const seen = new Set<number>();
  for (const c of doc.chunks) {
    if (typeof c.chunk_index !== "number" || !Number.isInteger(c.chunk_index) || c.chunk_index < 0) {
      return `${doc.doc_path}: every chunk needs a non-negative integer chunk_index`;
    }
    if (seen.has(c.chunk_index)) return `${doc.doc_path}: duplicate chunk_index ${c.chunk_index}`;
    seen.add(c.chunk_index);
    if (!c.text || typeof c.text !== "string") return `${doc.doc_path}#${c.chunk_index}: text is required`;
    if (!c.sha || !/^[0-9a-f]{64}$/.test(c.sha)) return `${doc.doc_path}#${c.chunk_index}: sha must be 64 hex characters`;
    if (!c.heading || typeof c.heading !== "string") return `${doc.doc_path}#${c.chunk_index}: heading is required`;
    if (typeof c.anchor !== "string") return `${doc.doc_path}#${c.chunk_index}: anchor is required`;
  }
  return null;
}

async function syncDoc(doc: IncomingDoc, dryRun: boolean) {
  const docPath = doc.doc_path as string;
  const chunks = doc.chunks as IncomingChunk[];

  const { data: stored, error: hashErr } = await db.rpc("muster_engine_doc_chunk_hashes", { p_doc_path: docPath });
  if (hashErr) throw new Error(`reading stored hashes for ${docPath} failed: ${hashErr.message}`);
  const existing = (stored ?? {}) as Record<string, { sha: string; visibility: string }>;

  let embedded = 0, unchanged = 0;
  const keep: number[] = [];

  for (const c of chunks) {
    const idx = c.chunk_index as number;
    keep.push(idx);
    const prior = existing[String(idx)];

    // Visibility is part of what has to match. Reclassifying a doc in the manifest
    // without touching its text must still rewrite the rows, or the reclassification
    // silently does nothing -- and the direction that fails quietly is the one that
    // leaves internal notes marked public.
    if (prior && prior.sha === c.sha && prior.visibility === doc.visibility) {
      unchanged++;
      continue;
    }
    if (dryRun) { embedded++; continue; }

    const embedding = await embedText(c.text as string);
    const { error: upErr } = await db.rpc("muster_engine_upsert_doc_chunk", {
      p_doc_path: docPath,
      p_doc_title: doc.doc_title,
      p_visibility: doc.visibility,
      p_heading: c.heading,
      p_anchor: c.anchor,
      p_chunk_index: idx,
      p_chunk_text: c.text,
      p_content_sha: c.sha,
      p_embedding: embedding,
      p_token_estimate: c.token_estimate ?? null,
    });
    if (upErr) throw new Error(`upsert ${docPath}#${idx} failed: ${upErr.message}`);
    embedded++;
  }

  // Prune last, and only after every chunk for this document has been written.
  // Pruning first would leave the corpus short if an embedding call failed midway.
  let pruned = 0;
  if (!dryRun) {
    const { data: deleted, error: pruneErr } = await db.rpc("muster_engine_prune_doc_chunks", {
      p_doc_path: docPath, p_keep: keep,
    });
    if (pruneErr) throw new Error(`prune ${docPath} failed: ${pruneErr.message}`);
    pruned = (deleted as number) ?? 0;
  }

  return { doc_path: docPath, visibility: doc.visibility, embedded, unchanged, pruned, total: chunks.length };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  const { data: secret } = await db.rpc("muster_engine_secret");
  const provided = req.headers.get("x-muster-secret") ?? "";
  if (!secret || !secretMatches(provided, secret as string)) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  let body: { documents?: IncomingDoc[]; dry_run?: boolean };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "body must be JSON" }, 400);
  }

  const documents = body.documents;
  if (!Array.isArray(documents) || documents.length === 0) {
    return json({ ok: false, error: "documents must be a non-empty array" }, 400);
  }

  // Validate everything up front. One bad document rejects the whole request rather
  // than leaving the corpus in a state that is half this sync and half the last one.
  for (const doc of documents) {
    const problem = validateDoc(doc);
    if (problem) return json({ ok: false, error: problem }, 400);
  }

  const dryRun = body.dry_run === true;
  const results = [];
  try {
    for (const doc of documents) results.push(await syncDoc(doc, dryRun));
  } catch (e) {
    const fatal = e instanceof FatalEmbedError;
    return json({
      ok: false,
      error: (e as Error).message,
      fatal,
      completed: results,
      note: fatal
        ? "aborted before spending further credit; documents listed in completed are fully written"
        : "documents listed in completed are fully written; re-run to continue",
    }, fatal ? 502 : 500);
  }

  return json({
    ok: true,
    dry_run: dryRun,
    results,
    summary: {
      documents: results.length,
      embedded: results.reduce((a, r) => a + r.embedded, 0),
      unchanged: results.reduce((a, r) => a + r.unchanged, 0),
      pruned: results.reduce((a, r) => a + r.pruned, 0),
    },
  });
});
