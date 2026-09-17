// EMAIL-* rule logic, tested against the shipped module.
//
//   node --experimental-strip-types --test tests/scan/email-auth.test.ts
//
// These rules accuse a customer's domain of being spoofable, at high severity,
// on the strength of a DNS lookup. The expensive failure is not missing a real
// problem — it is telling a correctly configured domain it has none. Most of
// what follows guards that direction.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  evaluateEmailAuth, mailDomain, dmarcCandidates,
  spfRecords, spfAllQualifier, parseDmarc, dmarcRecords,
  spfLookupTerms, evaluateSpfLookups, SPF_MAX_LOOKUPS,
} from "../../supabase/functions/muster-scan/email-auth.ts";

const ids = (fs: { rule_id: string }[]) => fs.map((f) => f.rule_id).sort();

const GOOD = {
  host: "example.com",
  spfTxt: ["v=spf1 include:_spf.google.com ~all"],
  dmarc: { name: "_dmarc.example.com", txt: ["v=DMARC1; p=reject; rua=mailto:dmarc@example.com"] },
  mx: ["10 aspmx.l.google.com."],
};

test("a correctly configured domain raises nothing", () => {
  assert.deepEqual(evaluateEmailAuth(GOOD), []);
});

test("softfail and strict fail are both accepted", () => {
  for (const all of ["~all", "-all"]) {
    const f = evaluateEmailAuth({ ...GOOD, spfTxt: [`v=spf1 include:_spf.google.com ${all}`] });
    assert.deepEqual(f, [], `${all} should not be a finding`);
  }
});

test("no SPF and no DMARC is two high findings", () => {
  const f = evaluateEmailAuth({ ...GOOD, spfTxt: [], dmarc: null });
  assert.deepEqual(ids(f), ["EMAIL-001", "EMAIL-004"]);
  assert.ok(f.every((x) => x.severity === "high"));
});

test("+all and ?all are flagged; ~all and -all are not", () => {
  for (const [all, flagged] of [["+all", true], ["?all", true], ["~all", false], ["-all", false]] as const) {
    const f = evaluateEmailAuth({ ...GOOD, spfTxt: [`v=spf1 mx ${all}`] });
    assert.equal(f.some((x) => x.rule_id === "EMAIL-002"), flagged, `${all} flagged=${flagged}`);
  }
});

test("an SPF record with no all mechanism is not flagged as permissive", () => {
  // Incomplete, but it does not assert "anyone may send" — inventing a finding
  // here would be exactly the false positive these rules must avoid.
  const f = evaluateEmailAuth({ ...GOOD, spfTxt: ["v=spf1 include:_spf.google.com"] });
  assert.ok(!f.some((x) => x.rule_id === "EMAIL-002"));
});

test("two SPF records is a permerror, and the permissive check is not also run", () => {
  const f = evaluateEmailAuth({ ...GOOD, spfTxt: ["v=spf1 include:a ~all", "v=spf1 include:b ~all"] });
  assert.deepEqual(ids(f), ["EMAIL-003"]);
  assert.match(f[0].detail, /RFC 7208/);
  // Same exposure as no SPF at all (EMAIL-001, high), so the same severity.
  assert.equal(f[0].severity, "high");
});

test("non-SPF TXT records are ignored", () => {
  const f = evaluateEmailAuth({
    ...GOOD,
    spfTxt: ["google-site-verification=abc", "v=spf1 mx ~all", "MS=ms12345"],
  });
  assert.deepEqual(f, []);
});

test("DMARC p=none reports but does not enforce", () => {
  const f = evaluateEmailAuth({
    ...GOOD,
    dmarc: { name: "_dmarc.example.com", txt: ["v=DMARC1; p=none; rua=mailto:d@example.com"] },
  });
  assert.deepEqual(ids(f), ["EMAIL-005"]);
  assert.equal(f[0].severity, "medium");
});

test("quarantine and reject are both accepted as enforcing", () => {
  for (const p of ["quarantine", "reject"]) {
    const f = evaluateEmailAuth({
      ...GOOD, dmarc: { name: "_dmarc.example.com", txt: [`v=DMARC1; p=${p}; rua=mailto:d@example.com`] },
    });
    assert.deepEqual(f, [], `p=${p} should be clean`);
  }
});

test("a DMARC record with no rua is flagged low, and no rua on p=none gives both", () => {
  const noRua = evaluateEmailAuth({
    ...GOOD, dmarc: { name: "_dmarc.example.com", txt: ["v=DMARC1; p=reject"] },
  });
  assert.deepEqual(ids(noRua), ["EMAIL-006"]);
  assert.equal(noRua[0].severity, "low");

  const both = evaluateEmailAuth({
    ...GOOD, dmarc: { name: "_dmarc.example.com", txt: ["v=DMARC1; p=none"] },
  });
  assert.deepEqual(ids(both), ["EMAIL-005", "EMAIL-006"]);
});

test("two DMARC records is a permerror, and no policy is read from either", () => {
  const f = evaluateEmailAuth({
    ...GOOD,
    dmarc: { name: "_dmarc.example.com", txt: ["v=DMARC1; p=none;", "v=DMARC1; p=reject; rua=mailto:d@example.com"] },
  });
  assert.deepEqual(ids(f), ["EMAIL-007"]);
  assert.equal(f[0].severity, "high");
  assert.match(f[0].detail, /RFC 7489/);
});

// The reason EMAIL-007 is checked before any policy is read. This is the exact
// shape a half-finished fix leaves behind: the old p=none still there, a new
// p=reject added beside it. Receivers apply neither. If the evaluator read
// dmarcTxt[0] and the resolver happened to return the reject record first, the
// scan would come back clean and tell the customer they are protected.
test("a p=reject record beside a leftover p=none is never reported as clean", () => {
  for (const order of [
    ["v=DMARC1; p=reject; rua=mailto:d@example.com", "v=DMARC1; p=none;"],
    ["v=DMARC1; p=none;", "v=DMARC1; p=reject; rua=mailto:d@example.com"],
  ]) {
    const f = evaluateEmailAuth({ ...GOOD, dmarc: { name: "_dmarc.example.com", txt: order } });
    assert.deepEqual(ids(f), ["EMAIL-007"], `resolver order ${JSON.stringify(order)} must not change the verdict`);
  }
});

test("non-DMARC TXT records alongside one DMARC record are not counted as duplicates", () => {
  const f = evaluateEmailAuth({
    ...GOOD,
    dmarc: { name: "_dmarc.example.com", txt: ["some-other-verification=xyz", "v=DMARC1; p=reject; rua=mailto:d@example.com"] },
  });
  assert.deepEqual(f, []);
});

// The one that matters most.
test("a resolver failure reports nothing at all", () => {
  const f = evaluateEmailAuth({ host: "example.com", spfTxt: [], dmarc: null, mx: [], resolverFailed: true });
  assert.deepEqual(f, [],
    "a DNS outage must never manufacture a high-severity finding against a domain that may be correctly configured");
});

test("www is stripped, because mail authentication belongs to the organizational domain", () => {
  assert.equal(mailDomain("www.example.com"), "example.com");
  assert.equal(mailDomain("Example.COM."), "example.com");
  assert.equal(mailDomain("shop.example.com"), "shop.example.com");
});

test("DMARC lookup walks up, and stops before a public suffix", () => {
  assert.deepEqual(dmarcCandidates("www.example.com"), ["_dmarc.example.com"]);
  assert.deepEqual(dmarcCandidates("shop.example.com"), ["_dmarc.shop.example.com", "_dmarc.example.com"]);
  // Never queries _dmarc.co.uk and mistakes the registry's answer for the customer's.
  const uk = dmarcCandidates("shop.example.co.uk");
  assert.ok(!uk.includes("_dmarc.co.uk"), `walked into a public suffix: ${uk.join(", ")}`);
});

test("an inherited parent DMARC satisfies a subdomain", () => {
  const f = evaluateEmailAuth({
    host: "shop.example.com",
    spfTxt: ["v=spf1 mx -all"],
    dmarc: { name: "_dmarc.example.com", txt: ["v=DMARC1; p=reject; rua=mailto:d@example.com"] },
    mx: [],
  });
  assert.deepEqual(f, [], "a subdomain protected by its parent must not be reported as unprotected");
});

test("a domain with no MX is still judged, because spoofing does not need one", () => {
  const f = evaluateEmailAuth({ host: "parked.example", spfTxt: [], dmarc: null, mx: [] });
  assert.deepEqual(ids(f), ["EMAIL-001", "EMAIL-004"]);
});

test("parsers handle the shapes DNS actually returns", () => {
  assert.deepEqual(spfRecords(["V=SPF1 mx ~all"]), ["V=SPF1 mx ~all"], "case insensitive");
  assert.deepEqual(spfRecords(["v=spf1234 nope"]), [], "prefix match must not be greedy");
  assert.equal(spfAllQualifier("v=spf1 mx all"), "+", "a bare all defaults to pass");
  assert.equal(spfAllQualifier("v=spf1 include:a"), null);
  assert.equal(parseDmarc("v=DMARC1; P=Reject; rua=mailto:a@b.c").p, "Reject");
  assert.equal(parseDmarc("v=DMARC1;p=none;p=reject").p, "none", "first duplicate tag wins");
  assert.deepEqual(dmarcRecords(["v=DMARC1; p=none"]).length, 1);
  assert.deepEqual(dmarcRecords(["v=DMARC1000; p=none"]), [], "prefix match must not be greedy");
});

test("every finding names the domain and cites evidence", () => {
  const f = evaluateEmailAuth({ host: "www.acme.test", spfTxt: [], dmarc: null, mx: [] });
  for (const x of f) {
    assert.match(x.detail, /acme\.test/, `${x.rule_id} does not name the domain`);
    assert.ok(x.evidence_keys.length > 0, `${x.rule_id} cites no evidence`);
    assert.equal(x.location, "DNS: acme.test");
    assert.equal(x.confidence, "high");
  }
});

// --- EMAIL-009: SPF DNS lookup limit ----------------------------------------
//
// Most of these guard the direction that costs credibility: a record that is
// fine must never be reported as broken, and a walk that could not finish must
// never be reported as passing.

test("spfLookupTerms counts only the terms that cost a DNS lookup", () => {
  const terms = spfLookupTerms(
    "v=spf1 ip4:192.0.2.0/24 ip6:2001:db8::/32 include:_spf.google.com a mx ~all",
  );
  assert.deepEqual(terms.map((t) => t.kind), ["include", "a", "mx"]);
  assert.equal(terms[0].target, "_spf.google.com");
});

test("spfLookupTerms treats redirect= as a lookup and exp= as not one", () => {
  const terms = spfLookupTerms("v=spf1 exp=why.example.com redirect=_spf.example.net");
  assert.deepEqual(terms.map((t) => t.kind), ["redirect"]);
  assert.equal(terms[0].target, "_spf.example.net");
});

test("spfLookupTerms counts a and mx with or without a domain or CIDR", () => {
  const terms = spfLookupTerms("v=spf1 a:mail.example.com mx:example.org a/24 mx -all");
  assert.deepEqual(terms.map((t) => t.kind), ["a", "mx", "a", "mx"]);
});

test("spfLookupTerms ignores the qualifier prefix", () => {
  const terms = spfLookupTerms("v=spf1 -include:a.example ~include:b.example ?a +mx");
  assert.deepEqual(terms.map((t) => t.kind), ["include", "include", "a", "mx"]);
});

test("EMAIL-009 is silent at exactly the limit, which is legal", () => {
  const f = evaluateSpfLookups({
    host: "example.com",
    traversal: { count: SPF_MAX_LOOKUPS, chain: ["example.com"], incomplete: false },
  });
  assert.equal(f.length, 0);
});

test("EMAIL-009 fires one over the limit", () => {
  const f = evaluateSpfLookups({
    host: "example.com",
    traversal: { count: SPF_MAX_LOOKUPS + 1, chain: ["example.com"], incomplete: false },
  });
  assert.equal(f.length, 1);
  assert.equal(f[0].rule_id, "EMAIL-009");
  assert.equal(f[0].severity, "high");
  assert.match(f[0].detail, /11 DNS lookups/);
});

test("EMAIL-009 is silent when the resolver failed, so an outage is never a finding", () => {
  const f = evaluateSpfLookups({
    host: "example.com",
    traversal: { count: 40, chain: ["example.com"], incomplete: true },
    resolverFailed: true,
  });
  assert.equal(f.length, 0);
});

test("EMAIL-009 does not fire from a partial walk that is still under the limit", () => {
  // The count is a floor when a nested include could not be read. Saying
  // "under the limit" from an incomplete walk would be asserting a pass that
  // was never measured.
  const f = evaluateSpfLookups({
    host: "example.com",
    traversal: { count: 6, chain: ["example.com", "a.example"], incomplete: true },
  });
  assert.equal(f.length, 0);
});

test("EMAIL-009 still fires on a partial walk once already over, and marks the count a floor", () => {
  const f = evaluateSpfLookups({
    host: "example.com",
    traversal: { count: 14, chain: ["example.com", "a.example"], incomplete: true },
  });
  assert.equal(f.length, 1);
  assert.match(f[0].detail, /14\+ DNS lookups/);
});

test("EMAIL-009 names the included senders, because the count is not visible from the apex record", () => {
  const f = evaluateSpfLookups({
    host: "www.example.com",
    traversal: {
      count: 13,
      chain: ["example.com", "_spf.google.com", "servers.mcsv.net", "spf.protection.outlook.com"],
      incomplete: false,
    },
  });
  assert.match(f[0].detail, /_spf\.google\.com/);
  assert.match(f[0].detail, /servers\.mcsv\.net/);
  // www is stripped: mail authentication belongs to the organizational domain.
  assert.equal(f[0].location, "DNS: example.com");
});
