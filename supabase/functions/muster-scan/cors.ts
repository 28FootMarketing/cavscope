// SEC-017: CORS misconfiguration that allows credentialed cross-origin reads.
//
// Wired into index.ts as section 3b as of ENGINE_VERSION http-native-1.8.0.
// The scan_rules row stays inactive until a scan reports that version live
// -- see supabase/migrations/
// 20260923190000_muster_086_hardening_gap_rules_inactive.sql for the
// activation step; do not flip `active` before then.
//
// WHAT THE PROBE IS
//
// One extra GET to the homepage carrying `Origin: <PROBE_ORIGIN>`, a
// sentinel that can never legitimately appear in a real site's CORS
// allowlist: PROBE_ORIGIN uses the .invalid TLD, which RFC 2606 reserves
// specifically so it can never resolve to anything and can never be a real
// registered domain. If the response reflects it back in
// Access-Control-Allow-Origin, that is definitionally not an intentional
// allowlist entry -- no operator configures trust for a domain that cannot
// exist.
//
// WHAT IS FLAGGED, AND WHAT IS NOT
//
// Only exact reflection of the probed Origin combined with
// Access-Control-Allow-Credentials: true. That pair is the actually
// exploitable defect: a page on any attacker-controlled origin can issue a
// credentialed (cookie-carrying) request to this site and read the response
// in the visitor's browser. A bare wildcard `*`, or reflection without
// credentials, is deliberately NOT flagged -- browsers refuse to honour
// credentialed requests against a wildcard origin regardless of what the
// server sends, per the Fetch standard, so reporting it as exploitable would
// be the same category of error EMAIL-002 avoids by leaving `~all` alone:
// crying wolf on a configuration that cannot be abused the way the finding
// would claim.

export type Severity = "critical" | "high" | "medium" | "low" | "info";

export type CorsFinding = {
  rule_id: string;
  severity: Severity;
  title: string;
  detail: string;
  location: string;
  confidence: "high" | "medium" | "low";
  evidence_keys: string[];
};

/**
 * The Origin sent on the probe request. `.invalid` is IANA-reserved (RFC
 * 2606) to never resolve and never be assigned, so any response that trusts
 * it is trusting a domain that cannot exist -- proof the server reflects
 * whatever Origin arrives rather than checking it against a real allowlist.
 */
export const PROBE_ORIGIN = "https://cors-probe.invalid";

export type CorsProbeResult = {
  /** The Origin header index.ts sent -- must equal PROBE_ORIGIN for evaluateCors to mean anything. */
  probedOrigin: string;
  /** The response's Access-Control-Allow-Origin, or null if absent. */
  allowOrigin: string | null;
  /** Whether the response's Access-Control-Allow-Credentials was exactly "true". */
  allowCredentials: boolean;
};

export function evaluateCors(input: {
  result: CorsProbeResult;
  evidenceKey: string;
}): CorsFinding[] {
  const { result, evidenceKey } = input;
  if (!result.allowOrigin) return [];

  const reflected = result.allowOrigin.trim().toLowerCase() === result.probedOrigin.trim().toLowerCase();
  if (!reflected || !result.allowCredentials) return [];

  return [{
    rule_id: "SEC-017",
    severity: "high",
    title: "CORS misconfiguration allows credentialed cross-origin reads",
    detail: `The server was sent Origin: ${result.probedOrigin} -- a domain reserved by RFC 2606 to never exist -- and reflected it back in Access-Control-Allow-Origin with Access-Control-Allow-Credentials: true. This is not a real allowlist entry; it is the server trusting whatever Origin arrives. A page on any attacker-controlled domain can now issue a credentialed request to this site and read the response inside a signed-in visitor's browser.`,
    location: "response headers (Access-Control-Allow-Origin, Access-Control-Allow-Credentials)",
    confidence: "high",
    evidence_keys: [evidenceKey],
  }];
}
