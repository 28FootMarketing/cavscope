// Tier 1: the contract suite. No model, no network, no cost. Run it in CI and
// before every muster-agent deploy.
//
//   node --experimental-strip-types --test evals/ai-narrative/offline.test.ts
//
// It asserts two things at once. That the shipped parse and verification code
// in supabase/functions/muster-agent/narrative.ts behaves, and that each grader
// still detects the failure it was written for. The second is the part that
// keeps the suite honest over time.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  parseNarrativeResponse,
  verifyNarrativeCitations,
  tokensInNarrative,
  allowedCitations,
  NarrativeParseError,
  type NarrativeContext,
} from "../../supabase/functions/muster-agent/narrative.ts";
import { grade, GRADERS } from "./graders.ts";
import { CASES } from "./recorded/cases.ts";

const here = dirname(fileURLToPath(import.meta.url));

function loadFixture(name: string): NarrativeContext {
  const raw = readFileSync(join(here, "fixtures", `${name}.json`), "utf8");
  return JSON.parse(raw).context as NarrativeContext;
}

test("every fixture on disk is well formed", () => {
  const files = readdirSync(join(here, "fixtures")).filter((f) => f.endsWith(".json"));
  assert.ok(files.length >= 5, "expected at least five fixtures");
  for (const f of files) {
    const doc = JSON.parse(readFileSync(join(here, "fixtures", f), "utf8"));
    assert.equal(typeof doc.name, "string", `${f}: missing name`);
    assert.equal(typeof doc.description, "string", `${f}: missing description`);
    assert.ok(doc.context, `${f}: missing context`);
    assert.ok(Array.isArray(doc.context.findings), `${f}: findings must be an array`);
    assert.ok(["board", "plain", "technical"].includes(doc.context.audience), `${f}: bad audience`);
    for (const fi of doc.context.findings) {
      assert.equal(typeof fi.finding_id, "number", `${f}: finding_id must be numeric`);
      assert.ok(Array.isArray(fi.evidence_ids), `${f}: evidence_ids must be an array`);
    }
  }
});

test("allowedCitations covers finding ids and evidence ids", () => {
  const ctx = loadFixture("01-mixed-board");
  const allowed = allowedCitations(ctx);
  assert.ok(allowed.has("F4101"), "finding id missing");
  assert.ok(allowed.has("E88201"), "evidence id missing");
  assert.ok(!allowed.has("F9999"), "unissued id must not be allowed");
  // Five findings plus seven evidence ids.
  assert.equal(allowed.size, 12);
});

test("tokensInNarrative reads prose, not identifiers that merely contain a token", () => {
  assert.deepEqual(tokensInNarrative("Transport is insecure (F4101, E88201)."), ["F4101", "E88201"]);
  assert.deepEqual(tokensInNarrative("no ids here"), []);
  // Deduplicated, and F410 must not be pulled out of F4101.
  assert.deepEqual(tokensInNarrative("F4101 and again F4101"), ["F4101"]);
  assert.deepEqual(tokensInNarrative("ref REF4101 is not a citation"), []);
});

test("markdown fences are stripped rather than failing the SITREP", () => {
  const parsed = parseNarrativeResponse('```json\n{"headline":"h","narrative":"n","citations":[]}\n```');
  assert.equal(parsed.headline, "h");
});

test("an invented id in the narrative prose is caught even when citations[] is clean", () => {
  const ctx = loadFixture("01-mixed-board");
  const parsed = parseNarrativeResponse(
    JSON.stringify({
      headline: "h",
      narrative: "Transport is insecure (F4101). Card handling was non-conforming (F8888).",
      citations: ["F4101"],
      confidence: "high",
    }),
  );
  const out = verifyNarrativeCitations(ctx, parsed);
  assert.deepEqual(out.unverified_citations, ["F8888"]);
  assert.equal(out.confidence, "low", "a fabricated id must force confidence down");
});

test("verified citations are deduplicated and normalised", () => {
  const ctx = loadFixture("01-mixed-board");
  const parsed = parseNarrativeResponse(
    JSON.stringify({ headline: "h", narrative: "n", citations: ["f4101", "F4101", " F4102 ", "nonsense"], confidence: "medium" }),
  );
  const out = verifyNarrativeCitations(ctx, parsed);
  assert.deepEqual(out.citations, ["F4101", "F4102"]);
  assert.deepEqual(out.unverified_citations, []);
  assert.equal(out.confidence, "medium");
});

for (const c of CASES) {
  test(`recorded: ${c.name}`, () => {
    const ctx = loadFixture(c.fixture);

    if (c.expectParseError) {
      assert.throws(
        () => parseNarrativeResponse(c.raw),
        (e: unknown) => {
          assert.ok(e instanceof NarrativeParseError, `expected NarrativeParseError, got ${e}`);
          assert.match((e as Error).message, c.expectParseError!);
          return true;
        },
      );
      return;
    }

    const parsed = parseNarrativeResponse(c.raw);
    const out = verifyNarrativeCitations(ctx, parsed);
    const verdicts = grade({ ctx, parsed, out, raw: c.raw });

    const failed = verdicts.filter((v) => !v.passed).map((v) => v.id).sort();
    assert.deepEqual(
      failed,
      [...c.expectFailures].sort(),
      `${c.name}: ${verdicts.filter((v) => !v.passed).map((v) => `${v.id} -- ${v.detail}`).join(" | ") || "nothing failed"}`,
    );
  });
}

// An invariant of narrative.ts rather than a judgement about a model, so it
// lives here and not in graders.ts: nothing an id-shaped token can appear in
// may escape verification. If the prose scan is ever removed, this is what
// fails.
test("no id written anywhere in the output escapes verification", () => {
  for (const c of CASES) {
    if (c.expectParseError) continue;
    const ctx = loadFixture(c.fixture);
    const parsed = parseNarrativeResponse(c.raw);
    const out = verifyNarrativeCitations(ctx, parsed);
    const accounted = new Set([...out.citations, ...out.unverified_citations]);
    const declared = parsed.citations.map((x) => String(x).trim().toUpperCase()).filter((x) => /^[FE]\d+$/.test(x));
    for (const t of [...tokensInNarrative(parsed.narrative), ...declared]) {
      assert.ok(accounted.has(t), `${c.name}: ${t} was never checked against the input`);
    }
  }
});

test("every grader is exercised by at least one recorded case", () => {
  const covered = new Set(CASES.flatMap((c) => c.expectFailures));
  const uncovered = GRADERS.map((g) => g.id).filter((id) => !covered.has(id));
  assert.deepEqual(
    uncovered,
    [],
    `these graders have no case proving they still fire: ${uncovered.join(", ")}. ` +
      "A grader nothing tests is a grader that has quietly stopped protecting anything. " +
      "Add a recorded case that trips it, or delete the grader.",
  );
});
