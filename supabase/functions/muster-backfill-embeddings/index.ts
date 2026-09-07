import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Backfill embeddings for findings and evidence to enable retrieval search.
// Uses public RPC functions to access muster schema tables via PostgREST.

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// Raised for conditions that will fail identically on every remaining record --
// a missing key, a rejected key, an exhausted credit limit. These abort the run
// instead of burning one request per record, so a caller looping until
// total_remaining hits 0 stops rather than spinning against a dead key.
class FatalEmbedError extends Error {}

async function embedText(text: string): Promise<number[]> {
  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) throw new FatalEmbedError("OPENROUTER_API_KEY not set");

  const res = await fetch("https://openrouter.ai/api/v1/embeddings", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "authorization": `Bearer ${apiKey}`,
      "http-referer": "https://muster.28footsystems.com",
      "x-title": "MUSTER embedding backfill",
    },
    body: JSON.stringify({
      model: "text-embedding-3-small",
      input: text,
      encoding_format: "float",
    }),
    signal: AbortSignal.timeout(15000),
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    const message = `embedding failed (${res.status}): ${detail.slice(0, 300)}`;
    // 401 bad key, 402 out of credit, 403 spend limit exceeded, 429 rate limited.
    // None of these get better by trying the next record.
    if ([401, 402, 403, 429].includes(res.status)) throw new FatalEmbedError(message);
    throw new Error(message);
  }

  const payload = await res.json();
  const embedding = payload?.data?.[0]?.embedding;
  if (!Array.isArray(embedding) || embedding.length === 0) {
    throw new Error("embedding returned no vector");
  }
  return embedding;
}

async function backfillFindings(batchSize: number) {
  // Get findings without embeddings via RPC wrapper function
  const { data: findings, error: findError } = await db.rpc(
    "get_findings_without_embeddings",
    { p_limit: batchSize }
  );

  if (findError) throw new Error(`query failed: ${findError.message}`);
  if (!findings || findings.length === 0) {
    return { embedded: 0, remaining: 0, type: "findings" };
  }

  let embedded = 0;

  for (const finding of findings) {
    try {
      const chunkText = [finding.title, finding.detail]
        .filter((x) => x)
        .join("\n");

      const embedding = await embedText(chunkText);

      // Insert embedding via RPC wrapper function
      const { error: insertError } = await db.rpc(
        "insert_finding_embedding",
        {
          p_id: finding.id,
          p_finding_id: finding.id,
          p_organization_id: finding.organization_id,
          p_website_id: finding.website_id,
          p_chunk_text: chunkText,
          p_chunk_index: 0,
          p_embedding: embedding,
        }
      );

      if (insertError && !insertError.message.includes("duplicate")) {
        console.error(
          `failed to insert embedding for finding ${finding.id}:`,
          insertError
        );
      } else {
        embedded++;
      }

      await new Promise((resolve) => setTimeout(resolve, 100));
    } catch (e) {
      if (e instanceof FatalEmbedError) throw e;
      console.error(`failed to embed finding ${finding.id}:`, e);
    }
  }

  // Count remaining
  const { data: countResult, error: countError } = await db.rpc(
    "count_findings_without_embeddings"
  );

  if (countError) {
    console.error("count remaining error:", countError);
  }

  return {
    embedded,
    remaining: (countResult as number) || 0,
    type: "findings",
  };
}

async function backfillEvidence(batchSize: number) {
  // Get evidence without embeddings via RPC wrapper function
  const { data: evidences, error: findError } = await db.rpc(
    "get_evidence_without_embeddings",
    { p_limit: batchSize }
  );

  if (findError) throw new Error(`query failed: ${findError.message}`);
  if (!evidences || evidences.length === 0) {
    return { embedded: 0, remaining: 0, type: "evidence" };
  }

  let embedded = 0;

  for (const evidence of evidences) {
    try {
      const headers = evidence.headers ? JSON.stringify(evidence.headers) : "";
      const chunkText = [headers, evidence.excerpt]
        .filter((x) => x)
        .join("\n")
        .slice(0, 2000);

      if (!chunkText.trim()) continue;

      const embedding = await embedText(chunkText);

      // Insert embedding via RPC wrapper function
      const { error: insertError } = await db.rpc(
        "insert_evidence_embedding",
        {
          p_id: evidence.id,
          p_evidence_id: evidence.id,
          p_organization_id: evidence.organization_id,
          p_website_id: evidence.website_id,
          p_chunk_text: chunkText,
          p_chunk_index: 0,
          p_embedding: embedding,
        }
      );

      if (insertError && !insertError.message.includes("duplicate")) {
        console.error(
          `failed to insert embedding for evidence ${evidence.id}:`,
          insertError
        );
      } else {
        embedded++;
      }

      await new Promise((resolve) => setTimeout(resolve, 100));
    } catch (e) {
      if (e instanceof FatalEmbedError) throw e;
      console.error(`failed to embed evidence ${evidence.id}:`, e);
    }
  }

  // Count remaining
  const { data: countResult, error: countError } = await db.rpc(
    "count_evidence_without_embeddings"
  );

  if (countError) {
    console.error("count remaining error:", countError);
  }

  return {
    embedded,
    remaining: (countResult as number) || 0,
    type: "evidence",
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  try {
    const body = (await req.json().catch(() => ({}))) as Record<
      string,
      unknown
    >;
    const batchSize = Math.min(
      Math.max(1, (body.batch_size as number) || 5),
      50
    );
    const type = ((body.type as string) || "all").toLowerCase();

    const results = [];

    if (type === "findings" || type === "all") {
      const findingsResult = await backfillFindings(batchSize);
      results.push(findingsResult);
    }

    if (type === "evidence" || type === "all") {
      const evidenceResult = await backfillEvidence(batchSize);
      results.push(evidenceResult);
    }

    return json({
      ok: true,
      results,
      summary: {
        total_embedded: results.reduce(
          (sum, r) => sum + (r.embedded as number),
          0
        ),
        total_remaining: results.reduce(
          (sum, r) => sum + (r.remaining as number),
          0
        ),
      },
      next: results.some((r) => r.remaining > 0)
        ? "Call again to continue backfill"
        : "Backfill complete",
    });
  } catch (e) {
    console.error("backfill error:", e);
    if (e instanceof FatalEmbedError) {
      return json(
        {
          ok: false,
          fatal: true,
          error: (e as Error).message,
          next: "Backfill aborted. The embedding provider rejected the credential " +
            "(bad key, exhausted credit, or spend limit). Nothing was embedded on " +
            "this call and retrying will fail identically until the key is fixed.",
        },
        502
      );
    }
    return json(
      { ok: false, error: (e as Error).message },
      500
    );
  }
});
