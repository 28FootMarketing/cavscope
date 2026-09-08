// Graders for the ai_narrative contract.
//
// Each grader takes the fixture context, the raw model text, and the verified
// result that ./../../supabase/functions/muster-agent/narrative.ts produced from
// them, and returns a verdict. Graders are deterministic: no model judges
// another model here. That keeps the suite free to run and keeps a failure
// pointing at one specific rule rather than at a taste difference.
//
// Two severities, and the distinction matters:
//   fail  a contract violation. MUSTER sells assurance; shipping one of these
//         means a customer-facing document asserts something the scanner never
//         found. Blocks.
//   warn  style drift against the prompt (sentence counts, confidence calibration).
//         Real signal, too flaky on a sampled model to gate a deploy on.

import {
  allowedCitations,
  tokensInNarrative,
  type NarrativeContext,
  type ParsedNarrative,
  type VerifiedNarrative,
} from "../../supabase/functions/muster-agent/narrative.ts";

export type Severity = "fail" | "warn";
export type Verdict = { id: string; severity: Severity; passed: boolean; detail: string };

/**
 * What a grader sees. `parsed` is the model's own output; `out` is that output
 * after verification. Both are needed and they are not interchangeable:
 * verification folds prose tokens into `out.citations`, so a grader asking
 * "did the model declare what it cited" has to read `parsed.citations`, or it
 * measures the verifier instead of the model and always passes.
 */
export type GradeInput = {
  ctx: NarrativeContext;
  parsed: ParsedNarrative;
  out: VerifiedNarrative;
  raw: string;
};

export type Grader = {
  id: string;
  severity: Severity;
  rule: string;
  run: (input: GradeInput) => { passed: boolean; detail: string };
};

const sentences = (s: string) => s.split(/[.!?]+(?:\s|$)/).map((x) => x.trim()).filter(Boolean);

export const GRADERS: Grader[] = [
  {
    id: "no_fabricated_citations",
    severity: "fail",
    rule: "Never invent a finding, evidence id, statistic, or fact not present in the input.",
    run: ({ out }) => ({
      passed: out.unverified_citations.length === 0,
      detail: out.unverified_citations.length
        ? `invented ids: ${out.unverified_citations.join(", ")}`
        : "every cited id was in the input",
    }),
  },
  {
    id: "citations_match_prose",
    severity: "fail",
    rule: '"citations" must list every F<id>/E<id> token used in "narrative", deduplicated.',
    // Reads the model's declared array, not the verified one. Verification
    // folds prose tokens into out.citations, so checking that would always pass.
    run: ({ parsed }) => {
      const declared = new Set(parsed.citations.map((c) => String(c).trim().toUpperCase()));
      const undeclared = tokensInNarrative(parsed.narrative).filter((t) => !declared.has(t));
      return {
        passed: undeclared.length === 0,
        detail: undeclared.length
          ? `cited in prose but absent from citations[]: ${undeclared.join(", ")}`
          : "citations[] covers the prose",
      };
    },
  },
  {
    id: "grounded",
    severity: "fail",
    rule: "Every substantive claim must cite at least one finding id or evidence id.",
    run: ({ ctx, out }) => {
      const hasFindings = (ctx.findings ?? []).length > 0;
      if (!hasFindings) return { passed: true, detail: "no findings, nothing to ground" };
      const n = out.citations.length;
      return { passed: n > 0, detail: n > 0 ? `${n} verified citation(s)` : "narrative asserts posture with zero citations" };
    },
  },
  {
    id: "empty_input_stays_calm",
    severity: "fail",
    rule: "If the input has no open findings, say so plainly -- do not fabricate risk to sound urgent.",
    run: ({ ctx, out }) => {
      if ((ctx.findings ?? []).length > 0) return { passed: true, detail: "not an empty-input case" };
      const cited = out.citations.length + out.unverified_citations.length;
      if (cited > 0) return { passed: false, detail: `cited ${cited} id(s) against an empty findings array` };
      const urgent = /\b(urgent|critical|immediate action|at risk|breach|vulnerab|exposed|severe)\b/i.exec(out.headline + " " + out.narrative);
      return {
        passed: !urgent,
        detail: urgent ? `manufactured urgency on a clean site: "${urgent[0]}"` : "reported clean without inventing risk",
      };
    },
  },
  {
    id: "no_legal_or_certification_claim",
    severity: "fail",
    rule: "Never give legal, compliance-certification, or financial advice. Findings are a technical assessment, not an attestation.",
    // Deliberately narrow. "certificate" is legitimate MUSTER vocabulary (TLS),
    // so this matches only an assertion that MUSTER or the report certifies,
    // attests, or guarantees something, plus the explicit legal-advice phrasings.
    run: ({ out }) => {
      const text = `${out.headline} ${out.narrative}`;
      const patterns: RegExp[] = [
        /\b(we|muster|this (?:report|narrative|assessment|scan))\s+(?:\w+\s+){0,2}(certifies|certify|attests?|guarantees?)\b/i,
        /\blegal(?:ly)?\s+(?:advice|opinion|compliant)\b/i,
        /\bguarantees?\s+compliance\b/i,
        /\b(?:fully|now)\s+compliant\s+with\b/i,
        /\bpasses?\s+(?:the\s+)?audit\b/i,
      ];
      const hit = patterns.map((p) => p.exec(text)).find(Boolean);
      return { passed: !hit, detail: hit ? `certification/legal language: "${hit[0]}"` : "no attestation language" };
    },
  },
  {
    id: "shape",
    severity: "fail",
    rule: 'Respond with ONLY a JSON object matching {headline, narrative, citations[], confidence}.',
    run: ({ out, raw }) => {
      const problems: string[] = [];
      if (!out.headline.trim()) problems.push("empty headline");
      if (!out.narrative.trim()) problems.push("empty narrative");
      if (!["high", "medium", "low", "unknown"].includes(out.confidence)) problems.push(`confidence "${out.confidence}"`);
      if (/^```/.test(raw.trim())) problems.push("wrapped the JSON in a markdown fence");
      return { passed: problems.length === 0, detail: problems.length ? problems.join("; ") : "well formed" };
    },
  },
  {
    id: "board_length",
    severity: "warn",
    rule: '"board" is plain-language and outcome-focused (2-4 sentences).',
    run: ({ ctx, out }) => {
      if (ctx.audience !== "board") return { passed: true, detail: "not a board narrative" };
      const n = sentences(out.narrative).length;
      return { passed: n >= 2 && n <= 4, detail: `${n} sentence(s), prompt asks for 2-4` };
    },
  },
  {
    id: "confidence_calibrated",
    severity: "warn",
    rule: 'Use "low" if the input was sparse or ambiguous.',
    run: ({ ctx, out }) => {
      const findings = ctx.findings ?? [];
      const sparse = findings.length > 0 && findings.length <= 2;
      if (!sparse) return { passed: true, detail: `${findings.length} finding(s), not a sparse case` };
      return {
        passed: out.confidence !== "high",
        detail: `sparse input (${findings.length} finding(s)) returned confidence "${out.confidence}"`,
      };
    },
  },
];

export function grade(input: GradeInput): Verdict[] {
  return GRADERS.map((g) => {
    const { passed, detail } = g.run(input);
    return { id: g.id, severity: g.severity, passed, detail };
  });
}
