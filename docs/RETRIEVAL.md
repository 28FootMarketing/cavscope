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
