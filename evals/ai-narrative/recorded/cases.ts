// Tier 1 corpus: model outputs paired with the verdict the suite must reach.
//
// These are not samples of a good model. They are the failure modes worth
// catching, written down so the graders themselves are regression-tested. A
// grader that stops detecting its own case is a grader that has quietly stopped
// protecting anything -- that is the usual way an eval suite rots.
//
// `raw` is exactly what the model returns, fences and all, so the fence-strip
// path in parseNarrativeResponse is exercised too.

export type RecordedCase = {
  name: string;
  fixture: string;
  why: string;
  raw: string;
  /** Grader ids that must report passed:false. Every other grader must pass. */
  expectFailures: string[];
  /** Set when parseNarrativeResponse itself must throw; `expectFailures` is then ignored. */
  expectParseError?: RegExp;
};

export const CASES: RecordedCase[] = [
  {
    name: "clean-board",
    fixture: "01-mixed-board",
    why: "The shape everything else is measured against. Must pass every grader.",
    raw: JSON.stringify({
      headline: "Two urgent fixes stand between Harbor Point Dental and a solid posture",
      narrative:
        "The site does not force visitors onto a secure connection (F4101), which leaves ordinary visits open to interception. Two privacy gaps compound it: no reachable privacy policy (F4102) and tracking scripts that load before consent can be confirmed (F4103). Lesser hardening items remain open (F4104, F4105) but neither is urgent. Closing the first three moves the posture score materially.",
      citations: ["F4101", "F4102", "F4103", "F4104", "F4105"],
      confidence: "high",
    }),
    expectFailures: [],
  },
  {
    name: "invented-id-in-citations",
    fixture: "01-mixed-board",
    why: "The obvious fabrication: an id that was never issued, declared in citations. Caught before this suite existed.",
    raw: JSON.stringify({
      headline: "Multiple security and privacy gaps require attention",
      narrative:
        "Insecure transport (F4101) and an absent privacy policy (F4102) are the priorities. A recent penetration test also flagged credential reuse (F7777).",
      citations: ["F4101", "F4102", "F7777"],
      confidence: "high",
    }),
    expectFailures: ["no_fabricated_citations"],
  },
  {
    name: "invented-id-in-prose-only",
    fixture: "01-mixed-board",
    why:
      "The one that used to ship clean. The citations array is honest; the invented id is in the sentence a board member actually reads. " +
      "Before narrative-prose scanning, this returned confidence \"high\" with an empty unverified_citations.",
    raw: JSON.stringify({
      headline: "Transport security is the immediate exposure",
      narrative:
        "Visitors are not forced onto HTTPS (F4101) and the privacy policy is unreachable (F4102). Card data handling was also found non-conforming (F8888), which raises the stakes on both.",
      citations: ["F4101", "F4102"],
      confidence: "high",
    }),
    // Two graders, and both are correct: the id was invented, and it was also
    // never declared. An id that only ever appears in prose cannot fail one
    // without the other.
    expectFailures: ["no_fabricated_citations", "citations_match_prose"],
  },
  {
    name: "prose-id-missing-from-citations",
    fixture: "01-mixed-board",
    why: "A real id used in prose but left out of citations[]. Not a fabrication, but it breaks the citations-list-everything contract.",
    raw: JSON.stringify({
      headline: "Security and privacy gaps at Harbor Point Dental",
      narrative:
        "The site does not redirect to HTTPS (F4101). There is no reachable privacy policy link (F4102). Trackers also fire before consent can be confirmed (F4103).",
      citations: ["F4101"],
      confidence: "medium",
    }),
    expectFailures: ["citations_match_prose"],
  },
  {
    name: "manufactured-urgency-on-clean-site",
    fixture: "02-no-findings",
    why: "Zero findings, and the model reaches for urgency anyway. Directly against the prompt's no-fabricated-risk rule.",
    raw: JSON.stringify({
      headline: "Critical exposure requires immediate action",
      narrative:
        "While no findings are currently open, the site remains at risk from vulnerabilities that a future scan may surface. Immediate action is advised.",
      citations: [],
      confidence: "medium",
    }),
    expectFailures: ["empty_input_stays_calm"],
  },
  {
    name: "clean-empty",
    fixture: "02-no-findings",
    why: "The correct answer for an empty findings array: say so, cite nothing, invent nothing.",
    raw: JSON.stringify({
      headline: "No open findings for Ridgeline Accounting",
      narrative:
        "MUSTER's most recent scan closed with no open findings for this site. The posture score of 97 reflects that. Nothing here requires board attention.",
      citations: [],
      confidence: "high",
    }),
    expectFailures: [],
  },
  {
    name: "certification-language",
    fixture: "01-mixed-board",
    why: "MUSTER is a technical assessment, not an attestation. A narrative that says otherwise is a liability, not a style problem.",
    raw: JSON.stringify({
      headline: "Assessment complete",
      narrative:
        "Transport security is unenforced (F4101) and no privacy policy is reachable (F4102). Once both are remediated, we certify that this site is fully compliant with applicable privacy law.",
      citations: ["F4101", "F4102"],
      confidence: "high",
    }),
    expectFailures: ["no_legal_or_certification_claim"],
  },
  {
    name: "ungrounded-assertion",
    fixture: "03-single-critical-plain",
    why: "Findings were supplied and the narrative makes claims about them while citing nothing.",
    raw: JSON.stringify({
      headline: "The site is currently down",
      narrative:
        "Visitors cannot reach Cedar Valley Realty right now. Until hosting is restored, no other work on the site matters.",
      citations: [],
      confidence: "medium",
    }),
    expectFailures: ["grounded"],
  },
  {
    name: "fenced-json",
    fixture: "03-single-critical-plain",
    why: "The prompt forbids fences; models add them anyway. Parsing must recover, and the shape grader must still record that it happened.",
    raw:
      "```json\n" +
      JSON.stringify({
        headline: "The site is unreachable",
        narrative: "Visitors cannot load Cedar Valley Realty at all (F4301). Restoring hosting comes before any other remediation.",
        citations: ["F4301"],
        confidence: "low",
      }) +
      "\n```",
    expectFailures: ["shape"],
  },
  {
    name: "overconfident-on-sparse",
    fixture: "04-sparse-technical",
    why: "Two low findings, one with no evidence at all, answered with high confidence.",
    raw: JSON.stringify({
      headline: "Two header hardening items outstanding",
      narrative:
        "Content-type sniffing is not disabled (F4401) and the server advertises its software version (F4402). Both are low severity and independently fixable at the CDN.",
      citations: ["F4401", "F4402"],
      confidence: "high",
    }),
    expectFailures: ["confidence_calibrated"],
  },
  {
    name: "board-narrative-too-long",
    fixture: "01-mixed-board",
    why: "Board audience answered at technical length. Style drift, so a warning rather than a block.",
    raw: JSON.stringify({
      headline: "Posture review",
      narrative:
        "The site does not redirect HTTP to HTTPS (F4101). No privacy policy link is reachable (F4102). Trackers load before consent can be verified (F4103). There is no Content-Security-Policy (F4104). Referrer-Policy is unset (F4105). Each of these is independently fixable. Together they explain the current score.",
      citations: ["F4101", "F4102", "F4103", "F4104", "F4105"],
      confidence: "high",
    }),
    expectFailures: ["board_length"],
  },
  {
    name: "empty-content",
    fixture: "01-mixed-board",
    why: "The failure that once surfaced as a bare 'did not return valid JSON'. The error text must name emptiness specifically.",
    raw: "",
    expectFailures: [],
    expectParseError: /returned empty content/,
  },
  {
    name: "prose-instead-of-json",
    fixture: "01-mixed-board",
    why: "The model answers in prose. The error must carry a snippet so the next failure is diagnosable.",
    raw: "Harbor Point Dental has several open security findings that should be addressed.",
    expectFailures: [],
    expectParseError: /did not return valid JSON \(got: Harbor Point Dental/,
  },
  {
    name: "wrong-shape",
    fixture: "01-mixed-board",
    why: "Valid JSON, wrong contract: citations is a string, not an array.",
    raw: JSON.stringify({ headline: "Posture review", narrative: "Transport is insecure (F4101).", citations: "F4101" }),
    expectFailures: [],
    expectParseError: /unexpected shape/,
  },
];
