// SEC-014 / SEC-015 / SEC-020 / EMAIL-008: the supply-chain and transport-
// policy rules, kept pure so they can be tested without a resolver or a
// network. index.ts does the lookups and hands the answers in; everything
// below is a function of its arguments, the same split email-auth.ts uses.
//
// Why these three: the scanner already inventories third-party scripts (TP-001)
// and already resolves DNS (EMAIL-*), so all three are a few lines of logic on
// machinery that exists. They close the gaps named in docs/SCAN-RULES.md's "what
// the engine does not check", and SEC-014 is the only rule MUSTER has that
// produces direct evidence for OWASP A03:2025 Software Supply Chain Failures,
// which is new at #3 in the 2025 Top 10.

export type Severity = "critical" | "high" | "medium" | "low" | "info";

export type HardeningFinding = {
  rule_id: string;
  severity: Severity;
  title: string;
  detail: string;
  location: string;
  confidence: "high" | "medium" | "low";
  evidence_keys: string[];
};

// ---------------------------------------------------------------------------
// SEC-014: Subresource Integrity on third-party scripts
// ---------------------------------------------------------------------------

export type ScriptRef = {
  /** The src as written in the document. */
  src: string;
  /** Absolute host it resolves to, lowercased. */
  host: string;
  /** Whether the tag carries an integrity attribute. */
  hasIntegrity: boolean;
  /** Whether the tag carries crossorigin, which SRI requires cross-origin. */
  hasCrossOrigin: boolean;
};

/**
 * Hosts whose scripts are MEANT to change without notice: tag managers,
 * analytics, chat widgets, ad pixels. Subresource Integrity pins a hash, so on
 * one of these it does not harden anything -- it breaks the tag the next time
 * the vendor ships, which is usually within days.
 *
 * Excluding them is not leniency, it is the difference between a finding an
 * operator can act on and one they cannot. "Add SRI to Google Tag Manager" is
 * advice that breaks the site, and a rule that issues it costs more credibility
 * than the finding is worth -- the same reasoning that keeps DKIM out of the
 * EMAIL family.
 *
 * The consequence is stated in the finding rather than hidden: a tag manager is
 * still unpinned third-party code, and SEC-014 says so while pointing at the
 * control that actually applies (CSP, and vendor review) instead of SRI.
 */
const MUTABLE_BY_DESIGN = [
  /googletagmanager\.com/i,
  /google-analytics\.com|analytics\.google\.com/i,
  /doubleclick\.net|googleadservices\.com|googlesyndication\.com/i,
  /connect\.facebook\.net|facebook\.com/i,
  /hotjar\.com/i,
  /clarity\.ms/i,
  /analytics\.tiktok\.com|tiktok\.com/i,
  /snap\.licdn\.com|linkedin\.com/i,
  /static\.ads-twitter\.com/i,
  /fullstory\.com/i,
  /segment\.com|segment\.io/i,
  /hubspot\.com|hs-scripts\.com|hs-analytics\.net|hsforms\.net/i,
  /mixpanel\.com/i,
  /amplitude\.com/i,
  /pinimg\.com|pinterest\.com/i,
  /leadconnectorhq\.com|msgsndr\.com/i,
  /intercom\.io|intercomcdn\.com/i,
  /crisp\.chat|tawk\.to|drift\.com|zdassets\.com/i,
  /stripe\.com|js\.stripe\.com/i,
  /recaptcha\.net|gstatic\.com\/recaptcha/i,
];

export function isMutableByDesign(host: string): boolean {
  return MUTABLE_BY_DESIGN.some((re) => re.test(host));
}

/**
 * Pull every <script src> from a document with the two attributes that decide
 * whether it is pinned. Parsed from the whole tag rather than the src alone,
 * because integrity and crossorigin live on the tag.
 *
 * Regex rather than a parser for the same reason the rest of this engine uses
 * one: there is no DOM here. It over-matches inside comments and CDATA, which
 * costs a spurious inventory entry at worst and never a missed script.
 */
export function extractScripts(html: string, pageUrl: string, pageHost: string): ScriptRef[] {
  const out: ScriptRef[] = [];
  for (const m of String(html || "").matchAll(/<script\b[^>]*>/gi)) {
    const tag = m[0];
    const srcMatch = tag.match(/\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i);
    if (!srcMatch) continue;
    const src = (srcMatch[1] ?? srcMatch[2] ?? srcMatch[3] ?? "").trim();
    if (!src) continue;
    let host: string;
    try {
      host = new URL(src, pageUrl).hostname.toLowerCase();
    } catch {
      continue;
    }
    if (!host || host === pageHost.toLowerCase()) continue;
    out.push({
      src,
      host,
      hasIntegrity: /\sintegrity\s*=\s*["']?[^"'\s>]+/i.test(tag),
      hasCrossOrigin: /\scrossorigin(\s|=|>|\/)/i.test(tag),
    });
  }
  return out;
}

export function evaluateSubresourceIntegrity(input: {
  scripts: ScriptRef[];
  evidenceKey: string;
}): HardeningFinding[] {
  const pinnable = input.scripts.filter((s) => !isMutableByDesign(s.host));
  if (pinnable.length === 0) return [];

  const unpinned = pinnable.filter((s) => !s.hasIntegrity);
  if (unpinned.length === 0) return [];

  const hosts = [...new Set(unpinned.map((s) => s.host))];
  const mutableCount = input.scripts.length - pinnable.length;

  // A pinned script still needs crossorigin to be checked at all cross-origin;
  // without it the browser fetches opaquely and cannot compare the hash. Worth
  // naming when it happens, because the tag looks protected and is not.
  const pinnedButOpaque = pinnable.filter((s) => s.hasIntegrity && !s.hasCrossOrigin);

  const parts = [
    `${unpinned.length} third-party script(s) from ${hosts.length} host(s) load without a Subresource Integrity hash: ${hosts.slice(0, 10).join(", ")}${hosts.length > 10 ? ", ..." : ""}.`,
    "If any of those hosts is compromised, the altered file executes in your visitors' browsers with full access to the page.",
  ];
  if (pinnedButOpaque.length > 0) {
    parts.push(`${pinnedButOpaque.length} other script(s) carry integrity but no crossorigin attribute, so the browser cannot verify the hash.`);
  }
  if (mutableCount > 0) {
    parts.push(`${mutableCount} further script(s) are from tag managers or analytics vendors that change their files by design; SRI is not applicable to those and they are excluded here. They remain unpinned third-party code, governed by CSP and vendor review rather than by a hash.`);
  }

  return [{
    rule_id: "SEC-014",
    severity: "medium",
    title: "Third-party scripts load without Subresource Integrity",
    detail: parts.join(" "),
    location: "<script src>",
    confidence: "high",
    evidence_keys: [input.evidenceKey],
  }];
}

// ---------------------------------------------------------------------------
// SEC-015: CAA
// ---------------------------------------------------------------------------

/**
 * The names a CA consults, nearest first. RFC 8659 has the issuer walk up from
 * the FQDN to the apex and stop at the first name with a CAA set, so a record on
 * the apex covers every subdomain that does not publish its own.
 *
 * Stops at the registrable domain rather than walking into the public suffix:
 * reading a registry operator's CAA and reporting it as the customer's would be
 * the same class of error the DMARC walk in email-auth.ts guards against.
 */
export function caaNames(host: string, registrableDomain: string): string[] {
  const h = String(host || "").trim().toLowerCase().replace(/\.$/, "");
  const apex = String(registrableDomain || "").trim().toLowerCase().replace(/\.$/, "");
  if (!h) return [];
  const names: string[] = [];
  let cur = h;
  while (cur && cur.length >= apex.length) {
    names.push(cur);
    if (cur === apex) break;
    const dot = cur.indexOf(".");
    if (dot === -1) break;
    cur = cur.slice(dot + 1);
  }
  return [...new Set(names)];
}

export function evaluateCaa(input: {
  host: string;
  /** Names queried and whatever CAA rdata each returned. */
  answers: Array<{ name: string; records: string[] }>;
  resolverFailed?: boolean;
  evidenceKey: string;
}): HardeningFinding[] {
  // A resolver outage must never become "this domain has no CAA". Same rule as
  // the SPF and DMARC checks: absence has to be an answer, not a timeout.
  if (input.resolverFailed) return [];

  const withRecords = input.answers.filter((a) => a.records.length > 0);
  if (withRecords.length > 0) return [];

  return [{
    rule_id: "SEC-015",
    severity: "low",
    title: "No CAA record restricts who may issue certificates",
    detail: `No CAA record is published at ${input.answers.map((a) => a.name).join(", ") || input.host}. Any public certificate authority may therefore issue a certificate for this domain, and a mis-issued certificate is what makes a convincing interception possible.`,
    location: `dns:${input.host}?type=CAA`,
    confidence: "high",
    evidence_keys: [input.evidenceKey],
  }];
}

// ---------------------------------------------------------------------------
// SEC-020: DNSSEC
// ---------------------------------------------------------------------------

/**
 * Checked at the registrable domain (apex), not at the scanned host itself.
 * A DS record is a delegation signer published in the PARENT zone -- it is
 * how a resolver decides whether to expect DNSSEC signatures under a name at
 * all -- and almost no operator signs an individual subdomain separately
 * from its apex. Querying at the apex is where a resolver looks regardless of
 * which subdomain of it is being resolved, and it is the same apex SEC-015
 * already computes for CAA, so this reuses it rather than re-deriving a
 * public-suffix stop here and letting the two drift.
 */
export function evaluateDnssec(input: {
  /** The registrable domain DS was queried at (SEC-015's own `apex`). */
  apex: string;
  /** DS records found at the apex, via DNS type 43. */
  records: string[];
  resolverFailed?: boolean;
  evidenceKey: string;
}): HardeningFinding[] {
  // Same rule as SPF, DMARC and CAA: a resolver outage must never become "no
  // DNSSEC", which would manufacture a finding out of an outage rather than
  // reporting an actual absence.
  if (input.resolverFailed) return [];
  if (input.records.length > 0) return [];

  return [{
    rule_id: "SEC-020",
    severity: "low",
    title: "DNSSEC not enabled",
    detail: `No DS record is published for ${input.apex} at its parent zone, so a resolver has no cryptographic way to detect a forged DNS answer anywhere under this domain. DNSSEC signing needs to be enabled with the DNS host and the resulting DS record published at the registrar -- a signed zone with no DS record at the parent is signed and unverifiable at the same time, which is the most common way this is half-done.`,
    location: `dns:${input.apex}?type=DS`,
    confidence: "high",
    evidence_keys: [input.evidenceKey],
  }];
}

// ---------------------------------------------------------------------------
// EMAIL-008: MTA-STS
// ---------------------------------------------------------------------------

export function evaluateMtaSts(input: {
  domain: string;
  /** TXT records at _mta-sts.<domain>. */
  txt: string[];
  /** The fetched https://mta-sts.<domain>/.well-known/mta-sts.txt, if it answered 200. */
  policy: string | null;
  /** MX hosts. A domain that receives no mail does not need a policy. */
  mx: string[];
  resolverFailed?: boolean;
  evidenceKey: string;
}): HardeningFinding[] {
  if (input.resolverFailed) return [];
  // No MX means nothing accepts mail here, so there is no transport to protect
  // and a finding would be noise on every parked or web-only domain.
  if (input.mx.length === 0) return [];

  const record = input.txt.find((t) => /^v=STSv1\s*;/i.test(t.trim()));

  if (!record) {
    return [{
      rule_id: "EMAIL-008",
      severity: "low",
      title: "No MTA-STS policy",
      detail: `${input.domain} accepts mail (${input.mx.length} MX host(s)) but publishes no MTA-STS policy at _mta-sts.${input.domain}. Without one, a sending server that cannot negotiate TLS will deliver the message in clear text rather than refuse, and an attacker positioned to strip STARTTLS can read it.`,
      location: `dns:_mta-sts.${input.domain}?type=TXT`,
      confidence: "high",
      evidence_keys: [input.evidenceKey],
    }];
  }

  // A TXT record with no policy file behind it is the failure mode worth
  // catching: senders look the policy up, get nothing, and fall back to exactly
  // the behaviour the record was published to prevent. It looks configured.
  if (!input.policy) {
    return [{
      rule_id: "EMAIL-008",
      severity: "low",
      title: "No MTA-STS policy",
      detail: `${input.domain} publishes an MTA-STS TXT record but https://mta-sts.${input.domain}/.well-known/mta-sts.txt did not return a policy. Senders that look it up get nothing and fall back to opportunistic TLS, so the record protects nobody while appearing configured.`,
      location: `https://mta-sts.${input.domain}/.well-known/mta-sts.txt`,
      confidence: "high",
      evidence_keys: [input.evidenceKey],
    }];
  }

  const mode = (input.policy.match(/^\s*mode\s*:\s*(\w+)/im) ?? [])[1]?.toLowerCase();
  if (mode === "testing" || mode === "none") {
    return [{
      rule_id: "EMAIL-008",
      severity: "low",
      title: "No MTA-STS policy",
      detail: `${input.domain} serves an MTA-STS policy in "${mode}" mode, which reports failures but does not enforce them. Senders still deliver over an unauthenticated connection when TLS cannot be negotiated. Move to mode: enforce once the reports are clean.`,
      location: `https://mta-sts.${input.domain}/.well-known/mta-sts.txt`,
      confidence: "high",
      evidence_keys: [input.evidenceKey],
    }];
  }

  return [];
}
