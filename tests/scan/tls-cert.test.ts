// SEC-023 / SEC-024: the TLS certificate a site presents, read off a socket. Engine http-native-1.16.0.
//
//   node --experimental-strip-types --test tests/scan/tls-cert.test.ts
//
// This file owns the ENGINE_VERSION equality pin (CLAUDE.md: the newest rule's test owns it);
// tests/scan/legal.test.ts and the others assert floors.
//
// The reader is checked against real TLS servers on loopback, with certificates made by openssl, and its
// DER parser is checked field by field against Node's own X.509 parser. Real internet servers were
// checked by hand when this was written (twelve sites, including customers', through a CONNECT tunnel; the
// reader agreed with Node on dates, serial and fingerprint for every one that Node would accept, and read
// the expired and self-signed ones Node refuses). CI has no network, so that part is not repeated here.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { X509Certificate } from "node:crypto";
import net from "node:net";
import tls from "node:tls";
import type { AddressInfo } from "node:net";
import { createServer } from "node:http";
import {
  buildClientHello, certHostProblem, certificateEvidence, daysBetween, evaluateCertificate, nodeNetConnect,
  parseCertificate, readCertificate, readFlight, type CertReading, type Connect,
} from "../../supabase/functions/cavscope-scan/tls-cert.ts";
import { loadEngine } from "../../tools/local-scan/adapt.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(root, p), "utf8");

let haveOpenssl = true;
try { execFileSync("openssl", ["version"], { stdio: "ignore" }); } catch { haveOpenssl = false; }
const dir = mkdtempSync(join(tmpdir(), "tls-cert-"));

function makeCert(name: string, keyArgs: string[], days: number, san: string) {
  const key = join(dir, `${name}.key`), crt = join(dir, `${name}.crt`);
  execFileSync("openssl", ["req", "-x509", "-newkey", ...keyArgs, "-nodes", "-keyout", key, "-out", crt, "-days", String(days),
    "-subj", "/CN=cert.example.test/O=Test Org", "-addext", `subjectAltName=${san}`], { stdio: "ignore" });
  return { key: readFileSync(key), cert: readFileSync(crt) };
}

async function listen(server: net.Server): Promise<number> {
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  return (server.address() as AddressInfo).port;
}

/** A Connect that ignores the host it is asked for and dials loopback, so SNI can still be the real name. */
async function loopback(port: number): Promise<Connect> {
  const c = await nodeNetConnect();
  assert.ok(c, "node:net must be available under Node");
  return (_host, _port) => c("127.0.0.1", port);
}

const SAN = "DNS:cert.example.test,DNS:*.example.test,DNS:other.example.test";

test("buildClientHello offers TLS 1.2 only, names the host, and never offers 1.3", () => {
  const hello = buildClientHello("cert.example.test", new Uint8Array(32));
  assert.equal(hello[0], 0x16);                       // handshake record
  assert.equal(hello[5], 0x01);                       // ClientHello
  assert.deepEqual([hello[9], hello[10]], [0x03, 0x03]);
  const text = Buffer.from(hello).toString("latin1");
  assert.ok(text.includes("cert.example.test"), "SNI carries the host");
  // Extension 0x002b is supported_versions. Offering it would let the server pick TLS 1.3 and encrypt the
  // certificate, which is the one thing this design depends on not happening.
  const exts = (() => {
    let p = 5 + 4 + 2 + 32;                           // record + handshake header + version + random
    p += 1 + hello[p];                                 // session id
    p += 2 + ((hello[p] << 8) | hello[p + 1]);         // cipher suites
    p += 1 + hello[p];                                 // compression
    const total = (hello[p] << 8) | hello[p + 1];
    p += 2;
    const types: number[] = [];
    for (let q = p; q < p + total;) { types.push((hello[q] << 8) | hello[q + 1]); q += 4 + ((hello[q + 2] << 8) | hello[q + 3]); }
    return types;
  })();
  assert.ok(exts.includes(0x0000), "server_name present");
  assert.ok(!exts.includes(0x002b), "supported_versions must NOT be offered");
});

test("certHostProblem refuses anything that is not a public host name", () => {
  for (const bad of [null, "", "127.0.0.1", "10.0.0.5", "[::1]", "::1", "localhost", "intranet", "printer.local", "db.internal", "a b.com", "-x.com"]) {
    assert.ok(certHostProblem(bad as string | null), `${bad} must be refused`);
  }
  for (const ok of ["example.com", "www.studyfetch.com", "shop.28footsystems.com", "xn--bcher-kva.example", "Example.COM."]) {
    assert.equal(certHostProblem(ok), null, `${ok} must be allowed`);
  }
});

test("readFlight: partial input waits, an alert is reported, garbage throws", () => {
  assert.deepEqual(readFlight(new Uint8Array([0x16, 0x03])), { kind: "more" });
  assert.deepEqual(readFlight(Uint8Array.from([0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x46])), { kind: "alert", description: "protocol_version" });
  assert.deepEqual(readFlight(Uint8Array.from([0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x28])), { kind: "alert", description: "handshake_failure" });
  assert.throws(() => readFlight(Uint8Array.from([0x47, 0x45, 0x54, 0x20, 0x2f])), /not a TLS record/);
});

for (const [label, keyArgs] of [["RSA", ["rsa:2048"]], ["ECDSA P-256", ["ec", "-pkeyopt", "ec_paramgen_curve:prime256v1"]]] as const) {
  test(`reads a ${label} certificate over a real TLS 1.2 handshake and agrees with Node's X.509 parser`, { skip: !haveOpenssl }, async () => {
    const { key, cert } = makeCert(label.replace(/\W/g, ""), [...keyArgs], 20, SAN);
    let sni = "";
    const server = tls.createServer({ key, cert, maxVersion: "TLSv1.2", SNICallback: (name, cb) => { sni = name; cb(null, tls.createSecureContext({ key, cert, maxVersion: "TLSv1.2" })); } });
    const port = await listen(server);
    try {
      const reading = await readCertificate("cert.example.test", { connect: await loopback(port), now: new Date() });
      assert.equal(reading.state, "ok", JSON.stringify(reading));
      if (reading.state !== "ok") return;
      assert.equal(sni, "cert.example.test", "the host name went out in SNI");
      assert.equal(reading.tls_version, "TLS 1.2");
      assert.equal(reading.chain_length, 1);

      const oracle = new X509Certificate(cert);
      const iso = (d: string) => new Date(d).toISOString().slice(0, 19) + "Z";
      assert.equal(reading.cert.not_before, iso(oracle.validFrom));
      assert.equal(reading.cert.not_after, iso(oracle.validTo));
      assert.equal(reading.cert.serial.replace(/^0+/, ""), oracle.serialNumber.toUpperCase().replace(/^0+/, ""));
      assert.equal(reading.cert.fingerprint_sha256, oracle.fingerprint256.replace(/:/g, ""));
      assert.equal(reading.cert.subject_cn, "cert.example.test");
      assert.equal(reading.cert.issuer_org, "Test Org");
      assert.equal(reading.cert.self_signed, true);
      assert.deepEqual(reading.cert.san, ["cert.example.test", "*.example.test", "other.example.test"]);
      assert.ok(reading.days_remaining >= 19 && reading.days_remaining <= 20, `days_remaining ${reading.days_remaining}`);
    } finally { server.close(); }
  });
}

test("a server that accepts only TLS 1.3 is 'unavailable: requires_tls13', not a certificate problem", { skip: !haveOpenssl }, async () => {
  const { key, cert } = makeCert("tls13", ["rsa:2048"], 20, SAN);
  const server = tls.createServer({ key, cert, minVersion: "TLSv1.3" });
  const port = await listen(server);
  try {
    const reading = await readCertificate("cert.example.test", { connect: await loopback(port) });
    assert.equal(reading.state, "unavailable");
    assert.equal(reading.state === "unavailable" && reading.reason, "requires_tls13");
    assert.deepEqual(evaluateCertificate({ host: "cert.example.test", reading, now: new Date(), evidenceKey: "k" }), []);
  } finally { server.close(); }
});

test("every failure is a reading, never a throw, and none raises a finding", async () => {
  const now = new Date();
  const check = async (connect: Connect | null, reason: string, timeoutMs = 400) => {
    const r = await readCertificate("cert.example.test", { connect, timeoutMs });
    assert.equal(r.state, "unavailable", JSON.stringify(r));
    assert.equal(r.state === "unavailable" && r.reason, reason);
    assert.deepEqual(evaluateCertificate({ host: "h", reading: r, now, evidenceKey: "k" }), []);
    assert.doesNotThrow(() => JSON.parse(certificateEvidence(r)));
  };

  await check(null, "no_socket_api");

  // nothing listening
  const dead = net.createServer(); const deadPort = await listen(dead); await new Promise((r) => dead.close(r));
  await check(await loopback(deadPort), "connect_failed");

  // accepts, never answers
  const silent = net.createServer((s) => { s.on("error", () => {}); });
  await check(await loopback(await listen(silent)), "timeout");
  silent.close();

  // answers with something that is not TLS
  const junk = net.createServer((s) => { s.on("error", () => {}); s.once("data", () => s.end("HTTP/1.1 400 Bad Request\r\n\r\n")); });
  await check(await loopback(await listen(junk)), "parse_error");
  junk.close();

  // answers with a handshake_failure alert
  const alert = net.createServer((s) => { s.on("error", () => {}); s.once("data", () => s.end(Buffer.from([0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x28]))); });
  await check(await loopback(await listen(alert)), "tls_alert");
  alert.close();

  // hangs up straight away
  const hangup = net.createServer((s) => { s.on("error", () => {}); s.once("data", () => s.destroy()); });
  await check(await loopback(await listen(hangup)), "closed_early");
  hangup.close();
});

test("the parser survives corrupted certificates: it returns or throws an Error, never hangs or crashes", { skip: !haveOpenssl }, async () => {
  const { cert } = makeCert("fuzz", ["rsa:2048"], 20, SAN);
  const der = new Uint8Array(new X509Certificate(cert).raw);
  let seed = 12345;
  const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  let threw = 0;
  for (let i = 0; i < 400; i++) {
    const mutated = der.slice(0, rnd() < 0.3 ? Math.floor(rnd() * der.length) : der.length);
    for (let k = 0; k < 1 + Math.floor(rnd() * 4); k++) mutated[Math.floor(rnd() * mutated.length)] = Math.floor(rnd() * 256);
    try { await parseCertificate(mutated); } catch (e) { assert.ok(e instanceof Error); threw++; }
  }
  assert.ok(threw > 50, "mutations should usually be rejected");
});

test("evaluateCertificate: thresholds, wording, and what stays quiet", () => {
  const now = new Date("2026-10-11T12:00:00Z");
  const reading = (daysLeft: number): CertReading => {
    const notAfter = new Date(now.getTime() + daysLeft * 86_400_000 + 3_600_000).toISOString().slice(0, 19) + "Z";
    return { state: "ok", host: "www.example.com", port: 443, tls_version: "TLS 1.2", chain_length: 2, days_remaining: daysBetween(now, notAfter), ms: 1,
      cert: { subject_cn: "www.example.com", issuer_cn: "R3", issuer_org: "Let's Encrypt", serial: "01", not_before: "2026-07-01T00:00:00Z", not_after: notAfter, san: ["www.example.com"], san_truncated: false, self_signed: false, fingerprint_sha256: "AB" } };
  };
  const run = (d: number) => evaluateCertificate({ host: "www.example.com", reading: reading(d), now, evidenceKey: "tls_certificate" });

  assert.deepEqual(run(60), []);
  assert.deepEqual(run(30), [], "30 days is the normal renewal window of automated authorities, not a finding");
  assert.deepEqual(run(15), []);
  for (const [d, sev] of [[14, "medium"], [8, "medium"], [7, "high"], [1, "high"], [0, "high"]] as const) {
    const f = run(d);
    assert.equal(f.length, 1, `${d} days`);
    assert.equal(f[0].rule_id, "SEC-024");
    assert.equal(f[0].severity, sev, `${d} days`);
    assert.equal(f[0].location, "tls:www.example.com");
    assert.deepEqual(f[0].evidence_keys, ["tls_certificate"]);
    assert.match(f[0].detail, /port 443/);
  }
  assert.match(run(0)[0].title, /expires today/);
  assert.match(run(1)[0].title, /in 1 day$/);
  assert.match(run(10)[0].title, /in 10 days$/);

  const expired = run(-3);
  assert.equal(expired.length, 1);
  assert.equal(expired[0].rule_id, "SEC-023");
  assert.equal(expired[0].severity, "critical");
  assert.match(expired[0].detail, /expired on 2026-10-0\d, \d+ days? ago/);
  // The fingerprint is (rule, page_url, location): days must not be in the location, or every day is a new finding.
  assert.equal(run(10)[0].location, run(9)[0].location);
});

test("the engine writes the certificate as evidence on every scan, and an unreadable one is never a finding", async () => {
  const server = createServer((req, res) => { res.writeHead(200, { "content-type": "text/html" }); res.end("<!doctype html><html lang=en><title>t</title><body>ok</body>"); });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const { port } = server.address() as AddressInfo;
  try {
    const mod = await import(await loadEngine()) as {
      runScan: (job: { scan_id: number; website_id: number; target_url: string; website_name: string }) =>
        Promise<{ findings: Array<{ rule_id: string }>; evidence: Array<{ key: string; kind: string; url: string; excerpt: string }> }>;
    };
    const result = await mod.runScan({ scan_id: 0, website_id: 0, target_url: `http://127.0.0.1:${port}/`, website_name: "t" });
    const row = result.evidence.find((e) => e.key === "tls_certificate");
    assert.ok(row, "tls_certificate evidence must be written whatever the outcome");
    assert.equal(row.kind, "tls_certificate");
    assert.deepEqual(JSON.parse(row.excerpt), { state: "unavailable", host: "127.0.0.1", port: 443, reason: "ip_literal", detail: null, ms: 0 });
    assert.ok(!result.findings.some((f) => f.rule_id === "SEC-023" || f.rule_id === "SEC-024"));
  } finally { server.close(); }
});

test("wiring: version, changelog, the held rules, and the evidence kind that must precede the deploy", () => {
  const engine = read("supabase/functions/cavscope-scan/index.ts");
  assert.match(engine, /const ENGINE_VERSION = "http-native-1\.16\.0";/);
  assert.match(engine, /1\.16\.0 adds SEC-023 \(the certificate the site presents has expired\)/);
  assert.match(engine, /import \{ certHostProblem, certificateEvidence, defaultConnect, evaluateCertificate, readCertificate, type CertReading \} from "\.\/tls-cert\.ts";/);
  assert.match(engine, /kind: "tls_certificate"/);

  const mig = read("supabase/migrations/" + migrationFile("tls_certificate_evidence_kind_and_rules"));
  assert.match(mig, /array_append\(v_old, 'tls_certificate'\)/);
  assert.match(mig, /\('SEC-023'[\s\S]*?false\),\s*\('SEC-024'[\s\S]*?false\)/, "both rules are inserted inactive");
  assert.match(mig, /BEFORE the engine that emits them deploys/);
  assert.doesNotMatch(mig.replace(/^--.*$/gm, ""), /active\s*=\s*true/i);
});

function migrationFile(name: string): string {
  const f = readdirSync(join(root, "supabase/migrations")).find((x) => x.endsWith(`_${name}.sql`));
  assert.ok(f, `migration ${name} not found`);
  return f;
}
