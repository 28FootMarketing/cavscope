// Tier 2: the real prompt against the real model. This spends OpenRouter credit
// and is never part of the offline suite for that reason.
//
//   OPENROUTER_API_KEY=... node --experimental-strip-types evals/ai-narrative/live.ts
//   ... --samples 3 --fixture 01-mixed-board --model anthropic/claude-sonnet-5
//   ... --json results.json
//
// What it is for: the offline suite proves the verification code and the graders
// work. Only this proves the *prompt* still holds. Run it after editing
// prompt.ts, before promoting a model change, and on a schedule if you want
// drift detection.
//
// It deliberately calls the model with the narrative prompt alone and no tool
// list. The shipped path runs the same prompt through runAgentLoop, which also
// offers tools; ai_narrative is handed a complete context and has no reason to
// call one, and excluding them keeps a failure attributable to the prompt rather
// than to a tool detour. That is a real difference from production, and it is
// the one place this suite is not testing the shipped code path end to end.
//
// Since migration 071 there is a second: production sends this prompt to the
// TENANT's endpoint and model, not to OpenRouter on MUSTER's key. That does not
// change what this measures -- the prompt is the same string either way -- but
// a result here is evidence about the prompt on the model you passed, not about
// whatever model a given customer has configured.

import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { AI_NARRATIVE_SYSTEM_PROMPT } from "../../supabase/functions/muster-agent/prompt.ts";
import {
  buildNarrativeUserPrompt,
  parseNarrativeResponse,
  verifyNarrativeCitations,
  NarrativeParseError,
  type NarrativeContext,
} from "../../supabase/functions/muster-agent/narrative.ts";
import { grade, type Verdict } from "./graders.ts";

const here = dirname(fileURLToPath(import.meta.url));

function arg(name: string, fallback?: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const MODEL = arg("model", process.env.OPENROUTER_MODEL ?? "anthropic/claude-sonnet-5")!;
const SAMPLES = Number(arg("samples", "3"));
const ONLY = arg("fixture");
const JSON_OUT = arg("json");
const KEY = process.env.MUSTER_OPENROUTER_API_KEY ?? process.env.OPENROUTER_API_KEY;

if (!KEY) {
  console.error(
    "No key. Set MUSTER_OPENROUTER_API_KEY or OPENROUTER_API_KEY.\n" +
      "This tier calls a real model and costs real money; there is no offline fallback here on purpose.\n" +
      "For the free suite: node --experimental-strip-types --test evals/ai-narrative/offline.test.ts",
  );
  process.exit(2);
}

type Fixture = { name: string; description: string; context: NarrativeContext };

const fixtures: Fixture[] = readdirSync(join(here, "fixtures"))
  .filter((f) => f.endsWith(".json"))
  .map((f) => JSON.parse(readFileSync(join(here, "fixtures", f), "utf8")) as Fixture)
  .filter((f) => !ONLY || f.name === ONLY);

if (fixtures.length === 0) {
  console.error(`No fixture matched --fixture ${ONLY}`);
  process.exit(2);
}

// Same call shape as runAgentLoop in index.ts: OpenRouter's OpenAI-compatible
// endpoint, same temperature, same max_tokens, reasoning off.
async function callModel(userPrompt: string): Promise<{ text: string; usage: unknown }> {
  const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "authorization": `Bearer ${KEY}`,
      "http-referer": "https://muster.partners",
      "x-title": "MUSTER ai_narrative eval",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 2000,
      temperature: 0.3,
      reasoning: { enabled: false },
      messages: [
        { role: "system", content: AI_NARRATIVE_SYSTEM_PROMPT },
        { role: "user", content: userPrompt },
      ],
    }),
    signal: AbortSignal.timeout(30000),
  });
  if (!res.ok) {
    throw new Error(`OpenRouter ${res.status}: ${(await res.text().catch(() => "")).slice(0, 300)}`);
  }
  const payload = await res.json();
  const choice = payload?.choices?.[0];
  if (choice?.finish_reason === "length") throw new Error("response truncated (finish_reason: length)");
  return { text: typeof choice?.message?.content === "string" ? choice.message.content : "", usage: payload?.usage };
}

type Run = {
  fixture: string;
  sample: number;
  ok: boolean;
  error?: string;
  verdicts?: Verdict[];
  output?: unknown;
  usage?: unknown;
};

const runs: Run[] = [];

console.log(`ai_narrative eval  model=${MODEL}  fixtures=${fixtures.length}  samples=${SAMPLES}\n`);

for (const f of fixtures) {
  console.log(`${f.name}  ${f.description}`);
  for (let s = 1; s <= SAMPLES; s++) {
    const label = `  sample ${s}/${SAMPLES}`;
    try {
      const { text, usage } = await callModel(buildNarrativeUserPrompt(f.context));
      const parsed = parseNarrativeResponse(text);
      const out = verifyNarrativeCitations(f.context, parsed);
      const verdicts = grade({ ctx: f.context, parsed, out, raw: text });
      const fails = verdicts.filter((v) => !v.passed && v.severity === "fail");
      const warns = verdicts.filter((v) => !v.passed && v.severity === "warn");

      runs.push({ fixture: f.name, sample: s, ok: fails.length === 0, verdicts, output: out, usage });

      if (fails.length === 0 && warns.length === 0) console.log(`${label}  pass`);
      else {
        console.log(`${label}  ${fails.length ? "FAIL" : "pass"}${warns.length ? ` (${warns.length} warn)` : ""}`);
        for (const v of [...fails, ...warns]) console.log(`      ${v.severity === "fail" ? "x" : "!"} ${v.id}: ${v.detail}`);
      }
    } catch (e) {
      const msg = e instanceof NarrativeParseError ? `unparseable: ${e.message}` : String((e as Error).message ?? e);
      runs.push({ fixture: f.name, sample: s, ok: false, error: msg });
      console.log(`${label}  FAIL  ${msg}`);
    }
  }
  console.log("");
}

const total = runs.length;
const passed = runs.filter((r) => r.ok).length;

// Per-grader failure rate across every run, which is what tells you whether a
// prompt edit helped. A single sample tells you almost nothing at temperature
// 0.3; a rate over a handful of samples does.
const byGrader = new Map<string, { fails: number; severity: string }>();
for (const r of runs) {
  for (const v of r.verdicts ?? []) {
    const e = byGrader.get(v.id) ?? { fails: 0, severity: v.severity };
    if (!v.passed) e.fails++;
    byGrader.set(v.id, e);
  }
}

console.log("─".repeat(64));
console.log(`${passed}/${total} runs passed every blocking grader`);
const offenders = [...byGrader.entries()].filter(([, e]) => e.fails > 0).sort((a, b) => b[1].fails - a[1].fails);
if (offenders.length) {
  console.log("\nfailure rate by grader:");
  for (const [id, e] of offenders) {
    console.log(`  ${e.severity === "fail" ? "x" : "!"} ${id.padEnd(32)} ${e.fails}/${total}`);
  }
}

if (JSON_OUT) {
  writeFileSync(JSON_OUT, JSON.stringify({ model: MODEL, samples: SAMPLES, at: new Date().toISOString(), runs }, null, 2));
  console.log(`\nwrote ${JSON_OUT}`);
}

// Non-zero only on a blocking grader. Warnings are reported, never fatal.
process.exit(passed === total ? 0 : 1);
