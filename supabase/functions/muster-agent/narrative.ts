// Pure, dependency-free half of the ai_narrative tool. Everything here is a
// function of its arguments: no database, no fetch, no Deno globals. That is
// deliberate -- it is what lets evals/ai-narrative exercise the *shipped* code
// instead of a copy of it. index.ts composes these with the model call; if you
// change the contract, change it here, and the eval moves with it.
//
// The contract these enforce is the one the tool advertises to agents in its
// SQL description: "Every claim cites a finding id (F<id>) or evidence id
// (E<id>) from the data this tool assembles; the model never sees or invents
// anything outside it."

export type NarrativeContext = {
  website_id?: unknown;
  website_name?: unknown;
  website_url?: unknown;
  organization_name?: unknown;
  posture_score?: unknown;
  posture_band?: unknown;
  audience?: unknown;
  findings?: Array<Record<string, unknown>>;
};

export type ParsedNarrative = {
  headline: string;
  narrative: string;
  citations: unknown[];
  confidence?: unknown;
};

export type VerifiedNarrative = {
  headline: string;
  narrative: string;
  citations: string[];
  unverified_citations: string[];
  confidence: string;
};

// A citation token as the prompt defines it: F or E followed by digits. Used
// both to validate a declared citation and to find tokens inside prose.
const TOKEN = /^[FE]\d+$/;
// Word-boundary form for scanning narrative text. \b before F/E stops it
// matching the tail of an identifier; the trailing (?!\w) stops F12 matching
// inside F123.
const TOKEN_IN_TEXT = /\b([FE]\d+)(?!\w)/g;

export function buildNarrativeUserPrompt(context: NarrativeContext): string {
  return [
    `Website: ${context.website_name} (${context.website_url})`,
    `Organization: ${context.organization_name}`,
    `Posture: ${context.posture_score}/100 (${context.posture_band})`,
    `Audience: ${context.audience}`,
    "",
    "Open findings (JSON array -- cite each entry's finding_id as F<id> and each id in its evidence_ids as E<id>):",
    JSON.stringify(context.findings ?? []),
  ].join("\n");
}

// Every id the model was actually handed. Anything outside this set is, by
// definition, invented.
export function allowedCitations(context: NarrativeContext): Set<string> {
  const allowed = new Set<string>();
  for (const f of context.findings ?? []) {
    if (f.finding_id !== undefined) allowed.add(`F${f.finding_id}`);
    for (const e of (f.evidence_ids as unknown[] | undefined) ?? []) allowed.add(`E${e}`);
  }
  return allowed;
}

// Citation tokens that appear in the narrative prose itself. The declared
// "citations" array is the model's own account of what it cited; this is what
// it actually wrote. They are not always the same, which is the point.
export function tokensInNarrative(narrative: string): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const m of narrative.matchAll(TOKEN_IN_TEXT)) {
    const t = m[1].toUpperCase();
    if (!seen.has(t)) { seen.add(t); out.push(t); }
  }
  return out;
}

export class NarrativeParseError extends Error {}

// The system prompt forbids markdown fences, but models add them often enough
// that stripping is cheaper than a failed SITREP. The error carries a snippet of
// what actually came back, so the next failure is diagnosable rather than opaque
// -- an earlier message said only "did not return valid JSON", which is what an
// empty string looks like too.
export function parseNarrativeResponse(finalText: string): ParsedNarrative {
  const jsonText = finalText.trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "")
    .trim();

  let parsed: unknown;
  try {
    parsed = JSON.parse(jsonText);
  } catch {
    throw new NarrativeParseError(
      jsonText.length === 0
        ? "ai narrative model returned empty content"
        : `ai narrative model did not return valid JSON (got: ${jsonText.slice(0, 160)})`
    );
  }

  const r = parsed as Record<string, unknown>;
  if (typeof r.headline !== "string" || typeof r.narrative !== "string" || !Array.isArray(r.citations)) {
    throw new NarrativeParseError("ai narrative model returned an unexpected shape");
  }
  return { headline: r.headline, narrative: r.narrative, citations: r.citations, confidence: r.confidence };
}

// Cross-check citations against the ids the model was actually given.
//
// Two sources are checked, not one. The declared "citations" array is the
// obvious one. The narrative prose is the one that matters: a fabricated F999
// written into a board-facing sentence and left out of the citations array is
// exactly the failure the citation contract exists to prevent, and checking
// only the array lets it through with confidence "high". Both are folded into
// the same allowed-set test.
//
// Fabricated tokens are never silently dropped: they land in
// unverified_citations and force confidence to "low", so a caller that renders
// nothing but headline and narrative still sees a degraded confidence.
export function verifyNarrativeCitations(
  context: NarrativeContext,
  parsed: ParsedNarrative,
): VerifiedNarrative {
  const allowed = allowedCitations(context);

  const seen = new Set<string>();
  const citations: string[] = [];
  const unverified: string[] = [];

  const consider = (raw: unknown) => {
    const token = String(raw).trim().toUpperCase();
    if (!TOKEN.test(token) || seen.has(token)) return;
    seen.add(token);
    (allowed.has(token) ? citations : unverified).push(token);
  };

  for (const c of parsed.citations) consider(c);
  for (const t of tokensInNarrative(parsed.narrative)) consider(t);

  const confidence = unverified.length
    ? "low"
    : (typeof parsed.confidence === "string" ? parsed.confidence : "unknown");

  return {
    headline: parsed.headline,
    narrative: parsed.narrative,
    citations,
    unverified_citations: unverified,
    confidence,
  };
}
