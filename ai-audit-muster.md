# Big Steele AI Audit: muster

**Score 33 / 100, grade F, level 1 Automated.** Programs can call it and work runs without a person, but no model is in the loop.

Gate: PASS (score 25 or more and level 1 Automated or above).

Profile: **Product** (the default; declare another with --profile or ai-audit.config.json). Software people use directly; AI and automation serve the customer in the product.

Generated 2026-09-07 by @bigsteele/ai-audit on 60 files. Every finding cites files; no source or values were read out. Env files were never opened.

## Scorecard

| Group | Earned | Weight | Contributes |
|---|---|---|---|
| Automated surfaces | 14 / 25 | 25% | 14 |
| AI systems | 0 / 25 | 25% | 0 |
| Agents | 5 / 25 | 25% | 5 |
| Autonomy and operability | 14 / 25 | 25% | 14 |
| **Total** | | | **33 / 100 (F)** |

## Levels

| Level | Name | Means |
|---|---|---|
| 0 | Manual | operated by people through screens |
| 1 ◀ | Automated | programs can call it; work runs on schedules and webhooks; no model in the loop |
| 2 | AI-assisted | models answer or draft inside the product; people do the doing |
| 3 | Agentic | agents act through tools or an MCP server; a person owns the operation |
| 4 | Autonomous | an AI agent could run the whole software; operations reachable by machine, failures visible |

## Automated surfaces (14 / 25)

- API handlers (route files, serverless functions, framework routes) (6) — `supabase/functions/muster-agent/index.ts`, `supabase/functions/muster-alert-dispatch/index.ts`, `supabase/functions/muster-ghl-webhook/index.ts`, `supabase/functions/muster-scan/index.ts`, `supabase/functions/muster-stripe-webhook/index.ts`, +1 more
- Inbound webhooks (handlers or signature checks) (7) — `supabase/functions/muster-ghl-webhook/index.ts`, `supabase/functions/muster-stripe-webhook/index.ts`
- Schedules (cron jobs, scheduled functions, workflows) (1) — `supabase/migrations/20260904120400_muster_cron.sql`

| Criterion | Earned |
|---|---|
| API handlers a program can call | 8 / 10 |
| A machine-readable API description | 0 / 4 |
| Inbound webhooks from other systems | 4 / 4 |
| Work that runs on a schedule | 2 / 4 |
| Queues or event pipelines | 0 / 3 |

## AI systems (0 / 25)

_Nothing found._


| Criterion | Earned |
|---|---|
| A model provider integrated | 0 / 8 |
| Prompts written down as code | 0 / 4 |
| Structured output the software acts on | 0 / 4 |
| Retrieval over your own data | 0 / 4 |
| Voice or vision | 0 / 3 |
| AI runs on the server, not only in the browser | 0 / 2 |

## Agents (5 / 25)

- Tool definitions (1) — `supabase/functions/muster-agent/index.ts`

| Criterion | Earned |
|---|---|
| Tools a model may call | 5 / 9 |
| A loop that lets the model act until done | 0 / 5 |
| An MCP server exposing the software | 0 / 5 |
| Orchestration or MCP client use | 0 / 3 |
| Memory kept between runs | 0 / 3 |

## Autonomy and operability (14 / 25)

- Reach: 6 handlers (undocumented, counted at a quarter) and 1 tools against 0 pages a person uses (ratio 1; 1 with a full API description) (3)
- Reliability (retries, backoff, idempotency, dead letters) (1) — `supabase/functions/muster-alert-dispatch/index.ts`
- Guardrails (rate limits 0, authenticated machine surfaces 5, moderation / redaction / cost caps 0) (5) — `supabase/functions/muster-agent/index.ts`, `supabase/functions/muster-alert-dispatch/index.ts`, `supabase/functions/muster-ghl-webhook/index.ts`, `supabase/functions/muster-scan/index.ts`, `supabase/functions/muster-watchdog/index.ts`
- Documentation written for agents (AGENTS.md, CLAUDE.md, llms.txt, skills, server card) (1) — `CLAUDE.md`

| Criterion | Earned |
|---|---|
| Reach: machine surfaces against human pages | 8 / 8 |
| Machine surfaces that change things | 0 / 4 |
| Observability of what ran | 0 / 3 |
| Retries, backoff, idempotency | 3 / 3 |
| Evals or tests of AI behaviour | 0 / 3 |
| Guardrails and a human gate | 1 / 2 |
| Documentation written for agents | 2 / 2 |

## What raises the grade

Points are on the 100 scale under this profile's weights, largest first.

- **+8 A model provider integrated.** Call a model from the server side; a second provider or a router earns the last two.
- **+5 A loop that lets the model act until done.** Let the model call tools in a loop (maxSteps, tool_use handling, an agent runner) instead of one answer.
- **+5 An MCP server exposing the software.** Ship an MCP server so any agent (Claude, Cursor, ChatGPT) can operate your software directly.
- **+4 A machine-readable API description.** Publish an OpenAPI file or a GraphQL schema so an agent can read what exists without a person; the handlers you already have then count in full toward Reach. A capability inventory or typed contract schemas earn half.
- **+4 Prompts written down as code.** Keep system prompts in files under version control, one per job.
- **+4 Structured output the software acts on.** Ask the model for a schema (JSON schema, zod, structured output) so its answer can drive code, not only a chat.
- **+4 Retrieval over your own data.** Embed your data and search it (pgvector or a vector store) so the model answers from your records.
- **+4 Tools a model may call.** Define tools (functions with schemas) for the model; eight or more distinct tools earns the full nine.
- **+4 Machine surfaces that change things.** Let handlers and tools write, not only read: create the record, send the thing, close the loop.
- **+3 Queues or event pipelines.** Put long or retried work on a queue or an event pipeline instead of a request.
- **+3 Voice or vision.** Add a voice or image path where your customers already speak or send pictures.
- **+3 Orchestration or MCP client use.** Chain steps in a workflow engine or graph, or consume other systems' MCP tools.
- **+3 Memory kept between runs.** Store threads, runs and agent memory in tables so work survives a restart and a second run knows the first.
- **+3 Observability of what ran.** Trace and log every run (Sentry, Langfuse, OpenTelemetry, structured logs) so a failure is visible without a customer.
- **+3 Evals or tests of AI behaviour.** Write evals for the prompts and tools; a change to a prompt should fail a test before it fails a customer.
- **+2 API handlers a program can call.** Expose the app's operations as API handlers; 20 or more earns the full ten.
- **+2 Work that runs on a schedule.** Add scheduled jobs for the work a person currently remembers to do.
- **+2 AI runs on the server, not only in the browser.** Move model calls behind a server function so keys stay server-side and agents can call them too.
- **+1 Guardrails and a human gate.** Rate limits and authenticated surfaces earn one; a human approval gate for the risky actions earns the other.

## What to do with this

This audit is the reading. The build is the work.

Big Steele builds what this grade measures: the API surface, the model calls, the tools and the loop, the reach and the failure visibility that let an agent run the software. If you want the rubric's author to read this report and tell you the three changes that move the grade most, in the order to make them, send it in:

**bigsteele.com/scan** Upload this file. You get a written read back. No call required to get it, and no pitch inside it.

If the read turns into a build, it is the first mile of that engagement, not a sales conversation you sat through to get the read.


---

Big Steele AI Audit · bigsteele.com · the grade is a reading of the code as it is, cited file by file. It measures how ready the architecture is for agents, not whether the product works today: it is not a security review, not a health check, and it does not run anything. A broken deploy scores the same as a working one.
