// Email authentication rules (EMAIL-*): the DNS-only half, kept pure so it can
// be tested without a resolver. index.ts does the lookups and hands the answers
// in; everything below is a function of its arguments.
//
// Why this family exists: MUSTER checked 31 things and none of them was whether
// someone can send mail as the client's domain. Missing SPF and DMARC is the
// most common way a business gets impersonated, and it is invisible from HTTP,
// which is why a scanner built entirely on fetch() never saw it.
//
// What is deliberately NOT checked: DKIM. A DKIM record lives at
// <selector>._domainkey.<domain>, and the selector is chosen by whatever sends
// the mail. There is no way to enumerate selectors from outside, so a "no DKIM"
// finding would be a guess. Probing a handful of common selectors and reporting
// absence as a defect would produce false positives on correctly configured
// domains, which costs more credibility than the finding is worth.

export type Severity = "critical" | "high" | "medium" | "low" | "info";

export type EmailAuthFinding = {
  rule_id: string;
  severity: Severity;
  title: string;
  detail: string;
  location: string;
  confidence: "high" | "medium" | "low";
  evidence_keys: string[];
};

export type EmailAuthInput = {
  /** Host the scan resolved to, e.g. "www.example.com". */
  host: string;
  /** TXT records at the SPF domain (apex after stripping www). */
  spfTxt: string[];
  /** The _dmarc name that answered, and its TXT records. Null when nothing answered. */
  dmarc: { name: string; txt: string[] } | null;
  /** MX hosts, for context in the evidence. Absence is not itself a finding. */
  mx: string[];
  /** True when a lookup failed outright, so absence cannot be distinguished from error. */
  resolverFailed?: boolean;
};

/**
 * The domain SPF and DMARC are judged on. A website scan targets a web host,
 * but mail authentication belongs to the organizational domain, so a leading
 * "www." is dropped. Anything deeper is left alone rather than guessed at.
 */
export function mailDomain(host: string): string {
  const h = String(host || "").trim().toLowerCase().replace(/\.$/, "");
  return h.startsWith("www.") ? h.slice(4) : h;
}

/**
 * Multi-label public suffixes common enough to matter. NOT the full Public
 * Suffix List, which is thousands of entries and updated continuously -- that
 * is more than a scanner needs to carry, and stale copies of it cause the exact
 * error this list exists to prevent.
 *
 * The walk below stops at any of these. Getting it wrong in the other direction
 * costs one unnecessary lookup that returns nothing; getting it wrong this way
 * would read a registry operator's DMARC record and report it as the customer's.
 */
const MULTI_LABEL_SUFFIXES = new Set([
  "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "sch.uk",
  "com.au", "net.au", "org.au", "edu.au", "gov.au",
  "co.nz", "net.nz", "org.nz", "govt.nz",
  "co.za", "org.za", "net.za",
  "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
  "com.br", "com.mx", "com.ar", "com.sg", "com.hk", "com.tw", "com.tr",
  "co.in", "net.in", "org.in", "co.kr", "co.il", "com.cn", "net.cn", "org.cn",
]);

/**
 * Names to try for DMARC, nearest first.
 *
 * DMARC is published at _dmarc.<domain>, and a subdomain inherits the
 * organizational domain's policy unless that policy says otherwise. Checking
 * only the exact host would report "no DMARC" for a correctly protected
 * subdomain -- a high-severity finding against a domain that is fine, which is
 * the failure direction that costs the most credibility.
 *
 * So this walks up, and stops before a public suffix. Without that guard,
 * shop.example.co.uk would end up querying _dmarc.co.uk and reporting whatever
 * the registry publishes as the customer's policy.
 */
export function dmarcCandidates(host: string): string[] {
  const parts = mailDomain(host).split(".").filter(Boolean);
  const out: string[] = [];
  for (let i = 0; i + 2 <= parts.length; i++) {
    const name = parts.slice(i).join(".");
    // Reached a registry-operated suffix: everything at or above it belongs to
    // the registry, not the customer.
    if (i > 0 && MULTI_LABEL_SUFFIXES.has(name)) break;
    out.push(`_dmarc.${name}`);
    if (parts.length - i <= 2) break;
  }
  return out;
}

/** The SPF record, or null. Multiple are returned so the caller can flag them. */
export function spfRecords(txt: string[]): string[] {
  return (txt || []).map((t) => String(t).trim()).filter((t) => /^v=spf1(\s|$)/i.test(t));
}

/**
 * The "all" mechanism that ends an SPF record, which is what decides whether
 * the record actually asserts anything.
 *
 *   -all  fail      only listed senders are legitimate
 *   ~all  softfail  the common, recommended setting
 *   ?all  neutral   explicitly no opinion, so the record protects nothing
 *   +all  pass      every sender on the internet is authorised
 *
 * Only ?all and +all are findings. Flagging ~all would be crying wolf on a
 * majority of correctly configured domains.
 */
export function spfAllQualifier(record: string): "+" | "-" | "~" | "?" | null {
  const m = /(?:^|\s)([+\-~?]?)all(?:\s|$)/i.exec(String(record || ""));
  if (!m) return null;
  return (m[1] || "+") as "+" | "-" | "~" | "?";
}

/** DMARC tags as a lowercase map. Later duplicates are ignored, per RFC 7489. */
export function parseDmarc(record: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const part of String(record || "").split(";")) {
    const [rawK, ...rest] = part.split("=");
    if (!rawK || rest.length === 0) continue;
    const k = rawK.trim().toLowerCase();
    if (k && !(k in out)) out[k] = rest.join("=").trim();
  }
  return out;
}

export function dmarcRecords(txt: string[]): string[] {
  return (txt || []).map((t) => String(t).trim()).filter((t) => /^v=dmarc1(\s*;|$)/i.test(t));
}

export function evaluateEmailAuth(input: EmailAuthInput): EmailAuthFinding[] {
  const domain = mailDomain(input.host);
  const at = `DNS: ${domain}`;
  const findings: EmailAuthFinding[] = [];

  // A resolver failure is not evidence of absence. Report nothing rather than
  // accusing a correctly configured domain of having no protection.
  if (input.resolverFailed) return findings;

  const spf = spfRecords(input.spfTxt);

  if (spf.length === 0) {
    findings.push({
      rule_id: "EMAIL-001", severity: "high",
      title: "No SPF record",
      detail: `No v=spf1 TXT record at ${domain}. Nothing tells receiving mail servers which systems may send as this domain, so anyone can.`,
      location: at, confidence: "high", evidence_keys: ["dns_spf"],
    });
  } else if (spf.length > 1) {
    // RFC 7208 4.5: more than one SPF record is a permerror. The domain has
    // protection on paper and none in practice, which is worse than knowing.
    findings.push({
      // High, not medium: the exposure is identical to publishing no SPF at
      // all (EMAIL-001, high). Severity tracks what an attacker can do, not
      // how close the operator came to getting it right.
      rule_id: "EMAIL-003", severity: "high",
      title: "Multiple SPF records",
      detail: `${domain} publishes ${spf.length} v=spf1 records. RFC 7208 requires receivers to treat this as a permanent error, so SPF fails open and the records protect nothing. Merge them into one.`,
      location: at, confidence: "high", evidence_keys: ["dns_spf"],
    });
  }

  if (spf.length === 1) {
    const q = spfAllQualifier(spf[0]);
    if (q === "+" || q === "?") {
      findings.push({
        rule_id: "EMAIL-002", severity: "high",
        title: q === "+" ? "SPF authorises every sender" : "SPF asserts no policy",
        detail: q === "+"
          ? `The SPF record at ${domain} ends in "+all", which authorises every server on the internet to send as this domain. It is equivalent to publishing no SPF at all, while appearing configured.`
          : `The SPF record at ${domain} ends in "?all" (neutral), which explicitly declines to say whether unlisted senders are legitimate. Receivers cannot act on it.`,
        location: at, confidence: "high", evidence_keys: ["dns_spf"],
      });
    }
  }

  const dmarcTxt = input.dmarc ? dmarcRecords(input.dmarc.txt) : [];

  if (dmarcTxt.length === 0) {
    findings.push({
      rule_id: "EMAIL-004", severity: "high",
      title: "No DMARC record",
      detail: `No v=DMARC1 TXT record found for ${domain} (checked ${dmarcCandidates(input.host).join(", ")}). DMARC is what tells receivers to reject mail that fails SPF and DKIM; without it, a forged sender is delivered normally.`,
      location: at, confidence: "high", evidence_keys: ["dns_dmarc"],
    });
  } else if (dmarcTxt.length > 1) {
    // RFC 7489 6.6.3: a name with more than one DMARC record is treated as
    // having none. Same fail-open shape as multiple SPF records, and the same
    // severity as publishing no DMARC at all, because that is the effect.
    //
    // This must be checked BEFORE reading a policy. Reading dmarcTxt[0] here
    // would evaluate whichever record the resolver happened to return first --
    // and if that one said p=reject, the scan would report the domain as
    // protected while every receiver ignores all of its records. Telling a
    // client they are covered when they are not is worse than any missed
    // finding.
    findings.push({
      rule_id: "EMAIL-007", severity: "high",
      title: "Multiple DMARC records",
      detail: `${input.dmarc!.name} publishes ${dmarcTxt.length} v=DMARC1 records: ${dmarcTxt.map((t) => `"${t}"`).join(" and ")}. RFC 7489 requires receivers to treat a name with more than one record as having no DMARC policy at all, so none of them is applied. This is the usual result of adding a new record instead of editing the old one. Delete all but the intended record.`,
      location: at, confidence: "high", evidence_keys: ["dns_dmarc"],
    });
  } else {
    const tags = parseDmarc(dmarcTxt[0]);
    const policy = (tags.p || "").toLowerCase();
    const found = input.dmarc!.name;

    if (policy === "none" || policy === "") {
      findings.push({
        rule_id: "EMAIL-005", severity: "medium",
        title: policy === "none" ? "DMARC is monitoring only" : "DMARC record has no policy",
        detail: policy === "none"
          ? `The DMARC record at ${found} sets p=none, which asks receivers to report on forged mail but not to act on it. Mail impersonating this domain is still delivered. Move to quarantine, then reject, once the reports are clean.`
          : `The DMARC record at ${found} has no p= tag, so receivers have no instruction to apply. A DMARC record without a policy does nothing.`,
        location: at, confidence: "high", evidence_keys: ["dns_dmarc"],
      });
    }

    if (!tags.rua) {
      findings.push({
        rule_id: "EMAIL-006", severity: "low",
        title: "DMARC has no reporting address",
        detail: `The DMARC record at ${found} has no rua= address, so nobody receives the aggregate reports. Without them there is no way to know who is sending as this domain, or whether tightening the policy would break legitimate mail.`,
        location: at, confidence: "high", evidence_keys: ["dns_dmarc"],
      });
    }
  }

  return findings;
}
