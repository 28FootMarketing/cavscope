# Retrieval Search for muster-agent

MUSTER uses pgvector for semantic search over findings and evidence, enabling Claude to gather context and verify claims during narrative generation.

## How It Works

1. **Embeddings**: Finding titles/descriptions and evidence content are embedded using Claude's text-embedding-3-small (1536 dimensions)
2. **Search**: Claude calls `search_findings` or `search_evidence` with a query
3. **Ranking**: Results are ranked by cosine similarity, filtered by threshold
4. **Context**: Agent loop uses results to refine narratives across multiple steps

## Backfill Embeddings

Before search returns results, embeddings must be populated for existing findings and evidence.

### Manual Backfill

Run the backfill edge function to embed all findings and evidence:

```bash
curl -X POST https://<project>.supabase.co/functions/v1/muster-backfill-embeddings \
  -H "authorization: Bearer $ANON_KEY" \
  -H "content-type: application/json" \
  -d '{
    "type": "all",
    "batch_size": 10
  }'
```

**Parameters:**
- `type`: `"findings"`, `"evidence"`, or `"all"` (default: `"all"`)
- `batch_size`: Items per request, 1-50 (default: 5, recommended: 10)

**Response:**
```json
{
  "ok": true,
  "results": [
    { "embedded": 10, "remaining": 45, "type": "findings" },
    { "embedded": 8, "remaining": 120, "type": "evidence" }
  ],
  "summary": {
    "total_embedded": 18,
    "total_remaining": 165
  },
  "next": "Call again to continue backfill"
}
```

### Resumable Backfill

The backfill is idempotent and resumable. If a call times out or fails:
1. Call again with the same or smaller batch_size
2. It skips items with existing embeddings
3. Progress continues from where it left off

### Performance

- ~100ms per embedding via OpenRouter
- ~5-10 findings/evidence per request
- Backfill time ≈ (total items / batch_size) * 0.5-1 second per request

Example: 1000 findings + 5000 evidence at batch_size=10:
- ~550 total requests
- ~9-10 minutes total (with 100ms delays between requests)

### Automatic Backfill (Future)

A pg_cron job can run the backfill every 5 minutes (see migration 20260907211000). Uncomment when:
1. Embedding infrastructure is proven stable in staging
2. Cost is acceptable (OpenRouter embeddings: $0.02 per 1M tokens)
3. New findings arrive faster than backfill processes them

## Schema

### Finding Embeddings

```sql
SELECT
  finding_id,
  organization_id,
  website_id,
  chunk_text,        -- "title\ncategory\ndescription"
  embedding,          -- 1536-dim vector
  created_at
FROM muster.finding_embeddings;
```

### Evidence Embeddings

```sql
SELECT
  evidence_id,
  organization_id,
  website_id,
  chunk_text,        -- "response_headers\nexcerpt" (up to 2000 chars)
  embedding,          -- 1536-dim vector
  created_at
FROM muster.evidence_embeddings;
```

## Search Functions

### Search Findings

```sql
SELECT
  finding_id,
  title,
  category,
  severity,
  chunk_text,
  similarity              -- 0.0 to 1.0 (1.0 = identical)
FROM muster.q_search_findings(
  p_website_id := 123,
  p_query_embedding := '[...]'::vector,
  p_limit := 10,
  p_threshold := 0.6
);
```

### Search Evidence

```sql
SELECT
  evidence_id,
  finding_id,
  chunk_text,
  similarity              -- 0.0 to 1.0
FROM muster.q_search_evidence(
  p_website_id := 123,
  p_query_embedding := '[...]'::vector,
  p_limit := 10,
  p_threshold := 0.6
);
```

## In the Agent Loop

Claude calls tools during agentic iteration:

```
User: "Generate a narrative for website 3"
  ↓
Agent: "I'll search for findings about security and compliance"
  ↓
Tool: search_findings(website_id=3, query="security practices")
  ← Results: 5 findings about auth, TLS, encryption
  ↓
Tool: search_evidence(website_id=3, query="TLS certificate expiry")
  ← Results: 3 evidence chunks with HTTP headers
  ↓
Agent: "Now I have context. Here's the narrative..."
  ← Final output with citations
```

## Troubleshooting

**Search returns empty results:**
- Check that embeddings exist: `SELECT COUNT(*) FROM muster.finding_embeddings;`
- Run backfill if count is 0
- Check threshold: lower threshold (0.4-0.5) for broader results

**Embedding API errors:**
- Verify OPENROUTER_API_KEY is set
- Check OpenRouter account has credits
- Embeddings are ~$0.02 per 1M input tokens (efficient)

**Similarity scores too low:**
- Query and content are semantically different
- Lower the threshold parameter (default 0.6 → try 0.5 or 0.4)
- Rephrase the query to match domain language

**Slow search:**
- IVFFLAT index may need tuning (lists=100 is default)
- For 10M+ findings, consider lists=200
- See Supabase pgvector performance guide

## Cost

Embeddings via OpenRouter text-embedding-3-small:
- ~$0.02 per 1M input tokens
- ~200 tokens per finding (title + category + description)
- ~300 tokens per evidence chunk
- Example: 1000 findings = ~0.2M tokens = ~$0.004

Monthly recurring cost depends on new findings/evidence volume.

## Documentation retrieval (`search_docs`)

A third corpus, added 2026-09-08: MUSTER's own `docs/`. Findings say what is wrong with a site and
evidence says what the scanner saw; neither says what any of it *means*. An agent asked "what does
`EMAIL-003` actually cost us" had the finding text and nothing else, and the gap between holding a
finding and being able to explain it is where a model starts composing.

`search_docs` takes no `website_id`. Documentation is not tenant data and is not scoped to a site.

### Chunking

`tools/embed-docs/chunk.ts` splits a markdown file on `##` headings. That is not a size choice: a
section is already the unit a person would quote, it has a heading that names it, and it has a
GitHub anchor, so a retrieved chunk can be cited as `docs/SCAN-RULES.md#email-authentication--7-rules`
and the reader lands on the exact text the agent read. Chunking by token count instead would retrieve
fragments nobody can go verify, which is the opposite of how the rest of MUSTER cites.

Details that are load-bearing:

- Every chunk's stored text is prefixed with the document title and heading. The embedding is of the
  text as stored, and a body that reads "Merge them into one." carries no signal about SPF without
  the heading above it.
- A `##` inside a fenced code block is sample output, not a heading. So is a split point: a
  paragraph break is only a break at fence depth zero, or one chunk ends up holding half a command.
- Content above the first `##` becomes chunk 0 under the document title, so the paragraph that says
  what a document is for is not silently dropped.

### Visibility

`docs/` is not uniformly publishable, and this is the part to get right before adding a document.

| Visibility | Reachable by | Today |
|---|---|---|
| `public` | any agent key with `read` | `docs/SCAN-RULES.md` |
| `internal` | a **platform-scoped** key (`organization_id` null) that also carries `admin` | everything else |

An org-scoped key with the `admin` scope is an admin of **one organization**. That does not make
MUSTER's own infrastructure notes theirs to read, and `muster_engine_search_docs` requires both
conditions, not either. Verified live: a tenant key carrying `read` **and** `admin` searching for
the exact text of `docs/EMAIL.md` gets back only `SCAN-RULES.md` sections.

Classification lives in `tools/embed-docs/manifest.json`. A file absent from it is **refused**, not
defaulted — defaulting to public would publish internal notes on a typo, and defaulting to internal
would quietly hide a doc someone meant to publish. `tests/docs/chunk.test.ts` asserts every `docs/*.md`
is classified, that the manifest names nothing that is not on disk, and that the seven internal
documents are still marked internal.

### Syncing

```bash
MUSTER_FUNCTIONS_URL=https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1 \
MUSTER_CRON_SECRET=... \
node --experimental-strip-types tools/embed-docs/sync.ts            # all of docs/
node --experimental-strip-types tools/embed-docs/sync.ts --dry-run  # what would change, no spend
node --experimental-strip-types tools/embed-docs/sync.ts docs/SCAN-RULES.md
```

The tool holds **no inference credential** and never talks to OpenRouter. It reads the repository,
chunks it, and posts text; `muster-embed-docs` holds the OpenRouter key and does the writing. So the
sync runs from a laptop or CI with nothing but the shared secret.

It is idempotent by content hash. Each chunk arrives with a sha256 of its text, and a chunk whose
stored hash **and visibility** both match is skipped without an embedding call — re-running against
unchanged docs costs nothing. Visibility is part of the comparison on purpose: reclassifying a
document without touching its text must still rewrite the rows, and the direction that fails quietly
is the one that leaves internal notes marked public.

Chunks that no longer exist in a file are pruned, and pruned **after** every chunk for that document
is written. Deleting a heading otherwise leaves its text searchable forever, which is the worst kind
of stale, because it still reads as current.

The whole corpus is 70 chunks, ~21k tokens, about $0.0004 to embed from scratch.

### Schema

```sql
select doc_path, doc_title, visibility, heading, anchor, chunk_index,
       chunk_text, content_sha, token_estimate, updated_at
from muster.doc_chunks;
```

RLS is on with **zero policies** — no tenant reads this table directly. The only read path is
`public.muster_engine_search_docs`, which is revoked from `anon` and `authenticated` and granted to
`service_role` alone, same posture as the finding and evidence wrappers.

**There is deliberately no IVFFLAT index on `doc_chunks`.** Findings and evidence carry one because
they grow without bound. `docs/` is a few hundred chunks; an IVFFLAT index with `lists=100` over ~70
rows puts under one row in each list and probes one list per query, so it would silently return a
near-empty result set and look exactly like "the docs were never embedded". A sequential scan over a
few hundred 1536-dim vectors is fast and exact. Add the index when the corpus justifies it, and set
`lists` from the real row count when you do.
