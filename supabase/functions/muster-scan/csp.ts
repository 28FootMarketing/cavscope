// SEC-018: a Content-Security-Policy present but permissive enough to defeat
// itself.
//
// Wired into index.ts right after the SEC-004 check as of ENGINE_VERSION
// http-native-1.8.0, reusing the same "headers" evidence key. The
// scan_rules row stays inactive until a scan reports that version live --
// see supabase/migrations/
// 20260923190000_muster_084_hardening_gap_rules_inactive.sql for the
// activation step; do not flip `active` before then.
//
// SEC-004 and SEC-018 are deliberately mutually exclusive: this module
// returns nothing when no CSP is present at all, because that case belongs
// to SEC-004 alone. Scoring both would be the same "one defect, one finding"
// mistake the AUTH-*/SEC-005/SEC-011 split in login.ts already guards
// against -- a CSP that does not exist cannot also be a CSP that is weak.
//
// WHAT COUNTS AS WEAK
//
// The directive that actually governs script execution is script-src, or
// default-src when script-src is not present -- CSP's own fallback rule.
// Within that effective directive:
//   - 'unsafe-inline' allows any inline <script> or on* handler to run,
//     which is the exact class of injection a CSP exists to stop.
//   - 'unsafe-eval' allows script built from strings at runtime (eval,
//     new Function, and friends) to run, the other classic injection vector.
//   - a bare '*' source (not a scoped wildcard like *.example.com) allows
//     script from literally any host.
//   - no script-src and no default-src at all means the policy restricts
//     something else (frame-ancestors alone, say) while leaving script
//     execution exactly as unrestricted as having no CSP -- worth naming
//     distinctly from the other three, because the operator likely believes
//     the page is covered.
//
// A directive value is a space-separated source list per the CSP spec, so
// tokens are matched by splitting on whitespace rather than by substring
// search -- substring search would flag a nonce like 'nonce-unsafe-inline-x'
// or a host literally named unsafe-inline.example.com as the keyword.

export type Severity = "critical" | "high" | "medium" | "low" | "info";

export type CspFinding = {
  rule_id: string;
  severity: Severity;
  title: string;
  detail: string;
  location: string;
  confidence: "high" | "medium" | "low";
  evidence_keys: string[];
};

function directiveValue(csp: string, name: string): string[] | null {
  // CSP directives are ';'-separated, each "name value1 value2 ...".
  // matchAll rather than a single match because a (malformed) policy could
  // repeat a directive; the spec says the first occurrence governs, so take
  // that one.
  for (const part of csp.split(";")) {
    const tokens = part.trim().split(/\s+/).filter(Boolean);
    if (tokens.length === 0) continue;
    if (tokens[0].toLowerCase() === name) return tokens.slice(1).map((t) => t.toLowerCase());
  }
  return null;
}

export function evaluateCspQuality(input: {
  /** The homepage's Content-Security-Policy header value, or null/absent -- SEC-004 owns that case. */
  csp: string | null;
  evidenceKey: string;
}): CspFinding[] {
  const { csp, evidenceKey } = input;
  if (!csp) return [];

  const scriptSrc = directiveValue(csp, "script-src");
  const defaultSrc = directiveValue(csp, "default-src");
  const effective = scriptSrc ?? defaultSrc;

  const problems: string[] = [];
  if (effective === null) {
    problems.push("no script-src or default-src directive is present, so script execution is not restricted at all");
  } else {
    if (effective.includes("'unsafe-inline'")) problems.push("'unsafe-inline' allows any inline script to run");
    if (effective.includes("'unsafe-eval'")) problems.push("'unsafe-eval' allows script built from strings at runtime to run");
    if (effective.includes("*")) problems.push("a bare '*' source allows script from any host");
  }
  if (problems.length === 0) return [];

  const governedBy = scriptSrc !== null ? "script-src" : defaultSrc !== null ? "default-src (no script-src is set)" : "neither directive";
  return [{
    rule_id: "SEC-018",
    severity: "medium",
    title: "Content-Security-Policy allows unsafe inline or eval scripts",
    detail: `A Content-Security-Policy is present, governed by ${governedBy}, but it does not stop the injection it exists to prevent: ${problems.join("; ")}. An attacker who can inject markup or a script tag into the page can run arbitrary script despite the policy.`,
    location: "response headers (Content-Security-Policy)",
    confidence: "high",
    evidence_keys: [evidenceKey],
  }];
}
