import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Backfill embeddings for findings and evidence to enable retrieval search.
// Safe to run repeatedly: checks for existing embeddings and skips.
// Returns progress report: how many embedded, how many remaining.
//
// Usage:
//   curl -X POST https://<project>.supabase.co/functions/v1/muster-backfill-embeddings \
//     -H "authorization: Bearer $ANON_KEY" \
//     -H "content-type: application/json" \
//     -d '{"batch_size": 10, "type": "findings"}'
//
// Parameters:
//   batch_size: Number of items to embed per request (default 5, max 50)
//   type: "findings", "evidence", or "all" (default "all")

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

async function embedText(text: string): Promise<number[]> {
  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) throw new Error("OPENROUTER_API_KEY not set");

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
    throw new Error(`embedding failed (${res.status}): ${detail.slice(0, 300)}`);
  }

  const payload = await res.json();
  const embedding = payload?.data?.[0]?.embedding;
  if (!Array.isArray(embedding) || embedding.length === 0) {
    throw new Error("embedding returned no vector");
  }
  return embedding;
}

async function backfillFindings(batchSize: number) {
  // Find findings without embeddings
  const { data: findings, error: findError } = await db
    .from("findings")
    .select("id, title, category, description, website_id, organization_id", {
      count: "exact",
    })
    .leftJoin(
      "finding_embeddings",
      "findings.id",
      "finding_embeddings.finding_id"
    )
    .is("finding_embeddings.finding_id", null)
    .limit(batchSize);

  if (findError) throw new Error(`query failed: ${findError.message}`);

  if (!findings || findings.length === 0) {
    return { embedded: 0, remaining: 0, type: "findings" };
  }

  let embedded = 0;

  for (const finding of findings) {
    try {
      // Chunk: title + category + description
      const chunkText = [
        finding.title,
        finding.category,
        finding.description,
      ]
        .filter((x) => x)
        .join("\n");

      const embedding = await embedText(chunkText);

      // Insert embedding
      const { error: insertError } = await db
        .from("finding_embeddings")
        .insert({
          id: finding.id,
          finding_id: finding.id,
          organization_id: finding.organization_id,
          website_id: finding.website_id,
          chunk_text: chunkText,
          chunk_index: 0,
          embedding: embedding,
        });

      if (insertError && !insertError.message.includes("duplicate")) {
        console.error(
          `failed to insert embedding for finding ${finding.id}:`,
          insertError
        );
      } else {
        embedded++;
      }

      // Small delay to avoid rate limits
      await new Promise((resolve) => setTimeout(resolve, 100));
    } catch (e) {
      console.error(`failed to embed finding ${finding.id}:`, e);
    }
  }

  // Count remaining
  const { count: remaining } = await db
    .from("findings")
    .select("id", { count: "exact", head: true })
    .leftJoin(
      "finding_embeddings",
      "findings.id",
      "finding_embeddings.finding_id"
    )
    .is("finding_embeddings.finding_id", null);

  return {
    embedded,
    remaining: remaining || 0,
    type: "findings",
  };
}

async function backfillEvidence(batchSize: number) {
  // Find evidence without embeddings
  const { data: evidences, error: findError } = await db
    .from("evidences")
    .select(
      "id, finding_id, website_id, organization_id, excerpt, response_headers",
      { count: "exact" }
    )
    .leftJoin(
      "evidence_embeddings",
      "evidences.id",
      "evidence_embeddings.evidence_id"
    )
    .is("evidence_embeddings.evidence_id", null)
    .limit(batchSize);

  if (findError) throw new Error(`query failed: ${findError.message}`);

  if (!evidences || evidences.length === 0) {
    return { embedded: 0, remaining: 0, type: "evidence" };
  }

  let embedded = 0;

  for (const evidence of evidences) {
    try {
      // Chunk: headers + excerpt
      const chunkText = [evidence.response_headers, evidence.excerpt]
        .filter((x) => x)
        .join("\n")
        .slice(0, 2000); // Limit chunk size

      if (!chunkText.trim()) continue;

      const embedding = await embedText(chunkText);

      // Insert embedding
      const { error: insertError } = await db
        .from("evidence_embeddings")
        .insert({
          id: evidence.id,
          evidence_id: evidence.id,
          organization_id: evidence.organization_id,
          website_id: evidence.website_id,
          chunk_text: chunkText,
          chunk_index: 0,
          embedding: embedding,
        });

      if (insertError && !insertError.message.includes("duplicate")) {
        console.error(
          `failed to insert embedding for evidence ${evidence.id}:`,
          insertError
        );
      } else {
        embedded++;
      }

      // Small delay to avoid rate limits
      await new Promise((resolve) => setTimeout(resolve, 100));
    } catch (e) {
      console.error(`failed to embed evidence ${evidence.id}:`, e);
    }
  }

  // Count remaining
  const { count: remaining } = await db
    .from("evidences")
    .select("id", { count: "exact", head: true })
    .leftJoin(
      "evidence_embeddings",
      "evidences.id",
      "evidence_embeddings.evidence_id"
    )
    .is("evidence_embeddings.evidence_id", null);

  return {
    embedded,
    remaining: remaining || 0,
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
    return json(
      { ok: false, error: (e as Error).message },
      500
    );
  }
});
