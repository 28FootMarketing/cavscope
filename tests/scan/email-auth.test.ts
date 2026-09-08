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
