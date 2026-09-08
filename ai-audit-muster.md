# Big Steele AI Audit: muster

**Score 70 / 100, grade C-, level 3 Agentic.** Agents take actions through tools or an MCP server; a person still owns the operation.

Gate: PASS (score 25 or more and level 1 Automated or above).

Profile: **Product** (the default; declare another with --profile or ai-audit.config.json). Software people use directly; AI and automation serve the customer in the product.

Generated 2026-09-08 by @bigsteele/ai-audit on 166 files. Every finding cites files; no source or values were read out. Env files were never opened.

## Scorecard

| Group | Earned | Weight | Contributes |
|---|---|---|---|
| Automated surfaces | 16 / 25 | 25% | 16 |
| AI systems | 14 / 25 | 25% | 14 |
| Agents | 18 / 25 | 25% | 18 |
| Autonomy and operability | 22 / 25 | 25% | 22 |
| **Total** | | | **70 / 100 (C-)** |

## Levels

| Level | Name | Means |
|---|---|---|
| 0 | Manual | operated by people through screens |
| 1 | Automated | programs can call it; work runs on schedules and webhooks; no model in the loop |
| 2 | AI-assisted | models answer or draft inside the product; people do the doing |
| 3 ◀ | Agentic | agents act through tools or an MCP server; a person owns the operation |
| 4 | Autonomous | an AI agent could run the whole software; operations reachable by machine, failures visible |

## Automated surfaces (16 / 25)

- API handlers (route files, serverless functions, framework routes) (9) — `supabase/functions/muster-agent/index.ts`, `supabase/functions/muster-alert-dispatch/index.ts`, `supabase/functions/muster-backfill-embeddings/index.ts`, `supabase/functions/muster-ghl-webhook/index.ts`, `supabase/functions/muster-resend-webhook/index.ts`, +4 more
- Inbound webhooks (handlers or signature checks) (20) — `supabase/functions/muster-ghl-webhook/index.ts`, `supabase/functions/muster-resend-webhook/index.ts`, `supabase/functions/muster-stripe-webhook/index.ts`, `supabase/functions/muster-resend-webhook/core.ts`
- Schedules (cron jobs, scheduled functions, workflows) (14) — `supabase/migrations/20260908012026_muster_028_cron_jobs_inactive_until_cutover.sql`, `supabase/migrations-shared-project/20260904035815_muster_cron.sql`, `supabase/migrations-shared-project/20260906032838_muster_alert_dispatch_cron.sql`, `supabase/migrations-shared-project/20260906032839_muster_autotriage_cron.sql`, `supabase/migrations-shared-project/20260906044502_muster_watchdog_cron.sql`, +4 more

| Criterion | Earned |
|---|---|
| API handlers a program can call | 8 / 10 |
| A machine-readable API description | 0 / 4 |
| Inbound webhooks from other systems | 4 / 4 |
| Work that runs on a schedule | 4 / 4 |
| Queues or event pipelines | 0 / 3 |

## AI systems (14 / 25)

- OpenRouter (3) — `evals/ai-narrative/live.ts`, `supabase/functions/muster-agent/index.ts`, `supabase/functions/muster-backfill-embeddings/index.ts`
- Models named in code: claude-sonnet-5, text-embedding-3-small (2) — `evals/ai-narrative/live.ts`, `supabase/functions/muster-agent/index.ts`, `supabase/functions/muster-backfill-embeddings/index.ts`
- Prompts (system prompts, prompt files) (4) — `evals/ai-narrative/live.ts`, `supabase/functions/muster-agent/index.ts`
- Retrieval: embeddings and vector search (7) — `supabase/migrations/20260907204744_muster_000_extensions.sql`, `supabase/migrations/20260907204804_muster_001_vector_into_public_to_match_source.sql`, `supabase/migrations/20260907212647_muster_005_remaining_tables_from_live.sql`, `supabase/migrations/20260907222630_muster_009_indexes.sql`, `supabase/migrations-shared-project/20260907022111_muster_agent_retrieval.sql`, +2 more

| Criterion | Earned |
|---|---|
| A model provider integrated | 6 / 8 |
| Prompts written down as code | 2 / 4 |
| Structured output the software acts on | 0 / 4 |
| Retrieval over your own data | 4 / 4 |
| Voice or vision | 0 / 3 |
| AI runs on the server, not only in the browser | 2 / 2 |

## Agents (18 / 25)

- Tool definitions (MCP) (1) — `supabase/functions/muster-agent/index.ts`
- Agent loops (a model calling tools until done) (8) — `supabase/functions/muster-agent/index.ts`
- MCP server (the software's abilities offered to any agent), 1 written by hand (JSON-RPC initialize, tools/list, tools/call) (2) — `supabase/functions/muster-agent/index.ts`, `.well-known/mcp/server-card.json`
- Memory and state kept between runs (threads, conversations, agent memory) (2) — `supabase/migrations/20260907212647_muster_005_remaining_tables_from_live.sql`, `supabase/migrations-shared-project/20260904035255_muster_onboarding_brand_flags_agents.sql`

| Criterion | Earned |
|---|---|
| Tools a model may call | 5 / 9 |
| A loop that lets the model act until done | 5 / 5 |
| An MCP server exposing the software | 5 / 5 |
| Orchestration or MCP client use | 0 / 3 |
| Memory kept between runs | 3 / 3 |

## Autonomy and operability (22 / 25)

- Reach: 9 handlers (undocumented, counted at a quarter) and 1 tools against 0 pages a person uses (ratio 1; 1 with a full API description) (3)
- Machine surfaces that write (create, update, delete), not only read (4) — `supabase/functions/_external/publish-due/index.ts`
- Observability (structured logs or traces in code) (1) — `supabase/functions/muster-resend-webhook/index.ts`
- Reliability (retries, backoff, idempotency, dead letters) (3) — `supabase/functions/_external/publish-due/index.ts`, `supabase/functions/muster-alert-dispatch/index.ts`, `supabase/functions/muster-resend-webhook/index.ts`
- Evals and tests of the AI behaviour (10) — `evals/ai-narrative/fixtures/01-mixed-board.json`, `evals/ai-narrative/fixtures/02-no-findings.json`, `evals/ai-narrative/fixtures/03-single-critical-plain.json`, `evals/ai-narrative/fixtures/04-sparse-technical.json`, `evals/ai-narrative/fixtures/05-full-cap-technical.json`, +3 more
- Guardrails (rate limits 0, authenticated machine surfaces 8, moderation / redaction / cost caps 2) (10) — `supabase/functions/_external/publish-due/index.ts`, `supabase/functions/muster-agent/index.ts`, `supabase/functions/muster-alert-dispatch/index.ts`, `supabase/functions/muster-backfill-embeddings/index.ts`, `supabase/functions/muster-ghl-webhook/index.ts`, +3 more
- Documentation written for agents (AGENTS.md, CLAUDE.md, llms.txt, skills, server card) (3) — `.well-known/mcp/server-card.json`, `AGENTS.md`, `CLAUDE.md`

| Criterion | Earned |
|---|---|
| Reach: machine surfaces against human pages | 8 / 8 |
| Machine surfaces that change things | 2 / 4 |
| Observability of what ran | 3 / 3 |
| Retries, backoff, idempotency | 3 / 3 |
| Evals or tests of AI behaviour | 3 / 3 |
| Guardrails and a human gate | 1 / 2 |
| Documentation written for agents | 2 / 2 |

## What raises the grade

Points are on the 100 scale under this profile's weights, largest first.

- **+4 A machine-readable API description.** Publish an OpenAPI file or a GraphQL schema so an agent can read what exists without a person; the handlers you already have then count in full toward Reach. A capability inventory or typed contract schemas earn half.
- **+4 Structured output the software acts on.** Ask the model for a schema (JSON schema, zod, structured output) so its answer can drive code, not only a chat.
- **+4 Tools a model may call.** Define tools (functions with schemas) for the model; eight or more distinct tools earns the full nine.
- **+3 Queues or event pipelines.** Put long or retried work on a queue or an event pipeline instead of a request.
- **+3 Voice or vision.** Add a voice or image path where your customers already speak or send pictures.
- **+3 Orchestration or MCP client use.** Chain steps in a workflow engine or graph, or consume other systems' MCP tools.
- **+2 API handlers a program can call.** Expose the app's operations as API handlers; 20 or more earns the full ten.
- **+2 A model provider integrated.** Call a model from the server side; a second provider or a router earns the last two.
- **+2 Prompts written down as code.** Keep system prompts in files under version control, one per job.
- **+2 Machine surfaces that change things.** Let handlers and tools write, not only read: create the record, send the thing, close the loop.
- **+1 Guardrails and a human gate.** Rate limits and authenticated surfaces earn one; a human approval gate for the risky actions earns the other.

## What to do with this

This audit is the reading. The build is the work.

Big Steele builds what this grade measures: the API surface, the model calls, the tools and the loop, the reach and the failure visibility that let an agent run the software. If you want the rubric's author to read this report and tell you the three changes that move the grade most, in the order to make them, send it in:

**bigsteele.com/scan** Upload this file. You get a written read back. No call required to get it, and no pitch inside it.

If the read turns into a build, it is the first mile of that engagement, not a sales conversation you sat through to get the read.

The written read is free. If you want it walked through live, the Scan Analysis call is $497, booked at the same page.


---

Big Steele AI Audit · bigsteele.com · the grade is a reading of the code as it is, cited file by file. It measures how ready the architecture is for agents, not whether the product works today: it is not a security review, not a health check, and it does not run anything. A broken deploy scores the same as a working one.
