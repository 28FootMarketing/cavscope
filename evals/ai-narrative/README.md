# `ai_narrative` eval suite

`ai_narrative` is the one MUSTER tool where a model writes text a customer reads
as assurance. Its contract, stated in the system prompt and repeated in the
tool's own description to agents, is:

> Every claim cites a finding id (F&lt;id&gt;) or evidence id (E&lt;id&gt;) from the data
> this tool assembles; the model never sees or invents anything outside it.

Nothing tested that the contract held. This suite does.

## Two tiers

| | Cost | Needs | Run it |
|---|---|---|---|
| **Offline** (`offline.test.ts`) | none | nothing | every commit, CI, before any `muster-agent` deploy |
| **Live** (`live.ts`) | real OpenRouter credit | a key, egress to `openrouter.ai` | after editing `prompt.ts`, before promoting a model change |

```bash
# offline: 22 assertions, no network, no spend
npm run eval:narrative

# live: real model, real money
OPENROUTER_API_KEY=... npm run eval:narrative:live
OPENROUTER_API_KEY=... node --experimental-strip-types evals/ai-narrative/live.ts \
  --samples 5 --model anthropic/claude-sonnet-5 --json /tmp/run.json
```

The offline tier proves the parsing and verification code works and that each
grader still detects the failure it was written for. Only the live tier proves
the **prompt** still holds. They answer different questions; neither substitutes
for the other.

## Why the shipped code is imported, not copied

The pure half of the tool lives in
`supabase/functions/muster-agent/narrative.ts` — prompt assembly, response
parsing, citation verification. `index.ts` composes it with the model call, and
this suite imports the same module.

That split is the point. An eval that reimplements the logic it is grading
passes forever while production drifts away from it. If you change the contract,
change `narrative.ts`, and the suite moves with it or breaks loudly.

## The graders

`fail` blocks a deploy. `warn` is real signal that is too flaky on a sampled
model to gate on.

| Grader | Sev | Rule it enforces |
|---|---|---|
| `no_fabricated_citations` | fail | No id that was not in the input, in prose or in `citations[]` |
| `citations_match_prose` | fail | `citations[]` declares every id the narrative actually used |
| `grounded` | fail | Findings supplied means at least one verified citation |
| `empty_input_stays_calm` | fail | Zero findings means say so, not manufacture urgency |
| `no_legal_or_certification_claim` | fail | A technical assessment, never an attestation |
| `shape` | fail | The JSON contract, unfenced, with a valid confidence |
| `board_length` | warn | Board audience is 2-4 sentences |
| `confidence_calibrated` | warn | Sparse input must not come back `high` |

Graders are deterministic. No model judges another model here, so a failure
points at one rule rather than at a taste difference, and the suite costs
nothing to run.

`citations_match_prose` reads the model's **declared** `citations` array, not
the verified output. Verification folds prose tokens into `out.citations`, so a
grader reading that would measure the verifier and always pass. This was caught
by the suite's own meta-test during construction.

## The defect this found

`verifyNarrativeCitations` originally checked only the `citations` array the
model declared. A model that wrote an invented `F8888` into a board-facing
sentence and left it out of that array passed clean, with `confidence: "high"`
and an empty `unverified_citations`.

That is precisely the failure the citation contract exists to prevent, and it
was the fail-open path. Verification now scans the narrative prose as well and
folds both sources through the same allowed-set test. The recorded case
`invented-id-in-prose-only` pins it.

Worth knowing separately: **nothing in the frontend renders
`unverified_citations`.** Forcing `confidence` to `"low"` is currently the only
signal a fabrication reached a reader. If a surface starts displaying narratives,
it should show that field.

## Adding a case

1. Drop a context into `fixtures/` shaped like what
   `muster_engine_agent_call(ctx, 'ai_narrative', …)` returns — see the `elsif
   p_tool = 'ai_narrative'` branch in
   `supabase/migrations/20260907235048_muster_020_shims_part2_final.sql`.
   Fixture copy is taken verbatim from `muster.scan_rules` so the model sees
   production-shaped input.
2. Add a `RecordedCase` in `recorded/cases.ts` with the exact grader ids that
   must fire. `expectFailures` is a whole-set assertion: a case tripping a
   grader you did not list fails the suite. That is deliberate — it stops cases
   from quietly accumulating unrelated failures.
3. A new grader needs a recorded case that trips it, or
   `every grader is exercised by at least one recorded case` fails. A grader
   nothing tests has quietly stopped protecting anything.

## Known gap

The live tier calls the model with the narrative prompt alone and no tool list.
The shipped path runs the same prompt through `runAgentLoop`, which also offers
the full tool catalogue. `ai_narrative` receives a complete context and has no
reason to call a tool, and excluding them keeps a failure attributable to the
prompt rather than to a tool detour — but it is a real difference from
production and the one place this suite is not end to end.
