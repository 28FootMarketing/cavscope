// SEC-023 / SEC-024: the TLS certificate a site actually presents.
//
// WHY THIS IS A SOCKET AND NOT A fetch()
//
// Everything else this engine does is fetch() (DNS goes over DNS-over-HTTPS for the same reason), and
// fetch() hands back a response, never the certificate that secured it. There is no spec-compliant way
// to read a certificate's expiry through it. Certificate Transparency logs are not a substitute: they say
// what was ISSUED for a name, not what the server is SERVING, and a site whose new certificate was issued
// but never installed would read as healthy while the old one ran out. That is the absence-as-a-pass
// failure this product is built not to commit, so the engine reads the served certificate itself.
//
// HOW, WITHOUT ANY CRYPTO
//
// Deno exposes no peer-certificate API, so this speaks just enough TLS to receive one. It opens a TCP
// connection, sends a TLS 1.2 ClientHello with the site's name in SNI, and reads the server's first flight.
// In TLS 1.2 the Certificate message is sent in the clear, so it is read straight off the wire and parsed
// as DER. No key exchange is attempted and nothing secret is derived: the connection is closed as soon as
// the Certificate message has arrived. The ClientHello offers TLS 1.2 only (no supported_versions), which is
// what keeps the certificate unencrypted -- a TLS 1.3 server would encrypt it. A server that accepts only
// TLS 1.3 answers with an alert, and that is reported as exactly that ("unavailable"), never as a
// certificate problem.
//
// WHAT THIS DOES NOT CLAIM
//
//  * It does not validate the chain, the signature or the host name. fetch() already refuses a site whose
//    certificate does not validate (the scan then reports it as unreachable), so this module only reads the
//    dates and names the server presented.
//  * It reads port 443 for one host name. Other names under the same domain have their own certificates.
//  * "unavailable" (could not connect, timed out, TLS 1.3 only, no socket API in this runtime) is a
//    different fact from "expired" and is recorded as evidence every scan, so a runtime that will not allow
//    this is visible rather than silent. The same reason dns_spf_chain is written whether or not it finds
//    anything: when a check's silence can be legitimate, it needs an artefact the engine writes anyway.
//
// Plain erasable TypeScript only (no enums, no parameter properties): tools/local-scan runs this file
// under Node's type stripping, and the edge function runs it under Deno.

export type Severity = "critical" | "high" | "medium" | "low" | "info";

export type CertFinding = {
  rule_id: string;
  severity: Severity;
  title: string;
  detail: string;
  location: string;
  confidence: "high" | "medium" | "low";
  evidence_keys: string[];
};

/** The slice of a socket this module needs. Deno.Conn satisfies it; tests wrap node:net. */
export type Conn = {
  read(p: Uint8Array): Promise<number | null>;
  write(p: Uint8Array): Promise<number>;
  close(): void;
};
export type Connect = (host: string, port: number) => Promise<Conn>;

export type CertInfo = {
  subject_cn: string | null;
  issuer_cn: string | null;
  issuer_org: string | null;
  serial: string;
  not_before: string;
  not_after: string;
  san: string[];
  san_truncated: boolean;
  self_signed: boolean;
  fingerprint_sha256: string;
};

export type CertReading =
  | { state: "ok"; host: string; port: number; tls_version: string; chain_length: number; cert: CertInfo; days_remaining: number; ms: number }
  | { state: "unavailable"; host: string; port: number; reason: string; detail: string | null; ms: number };

export const SEC_CERT_EXPIRED = "SEC-023";
export const SEC_CERT_EXPIRING = "SEC-024";
/** At or under this many days, the finding is high rather than medium. */
export const EXPIRING_HIGH_DAYS = 7;
/** At or under this many days there is a finding at all. See the rule's remediation for why it is not 30. */
export const EXPIRING_DAYS = 14;

const MAX_SAN = 20;
const MAX_FLIGHT_BYTES = 192 * 1024;

// ---------------------------------------------------------------------------
// Which hosts this will connect to
// ---------------------------------------------------------------------------

/**
 * Returns why a host must not be probed, or null. The scanner already fetches whatever site a tenant
 * registers; a raw connection to a name that is not a public site (a bare label, localhost, an address
 * literal) would be a different kind of request, so those are refused before any socket is opened.
 */
export function certHostProblem(host: string | null): string | null {
  if (!host) return "no_host";
  const h = host.toLowerCase().replace(/\.$/, "");
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(h) || h.includes(":") || /^\[.*\]$/.test(h)) return "ip_literal";
  if (!h.includes(".")) return "single_label";
  if (h === "localhost" || /\.(local|localhost|internal|lan|home|corp)$/.test(h)) return "internal_name";
  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(h)) return "not_a_hostname";
  return null;
}

// ---------------------------------------------------------------------------
// ClientHello
// ---------------------------------------------------------------------------

function u16(n: number): number[] { return [(n >> 8) & 0xff, n & 0xff]; }
function u24(n: number): number[] { return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]; }

// TLS 1.2 suites, most common first. The server picks one; none is ever used, so this is only about not
// being refused for having no suite in common.
const CIPHER_SUITES = [
  0xc02b, 0xc02f, 0xc02c, 0xc030, 0xcca9, 0xcca8, // ECDHE GCM / ChaCha
  0xc009, 0xc013, 0xc00a, 0xc014,                 // ECDHE CBC
  0x009e, 0x009f,                                  // DHE GCM
  0x009c, 0x009d, 0x002f, 0x0035,                  // RSA
  0x00ff,                                          // renegotiation SCSV
];

export function buildClientHello(host: string, random?: Uint8Array): Uint8Array {
  const rnd = random ?? crypto.getRandomValues(new Uint8Array(32));
  const name = new TextEncoder().encode(host);
  const ext = (type: number, body: number[]) => [...u16(type), ...u16(body.length), ...body];
  const extensions = [
    // server_name
    ...ext(0x0000, [...u16(name.length + 3), 0x00, ...u16(name.length), ...name]),
    // extended_master_secret, renegotiation_info
    ...ext(0x0017, []),
    ...ext(0xff01, [0x00]),
    // supported_groups: x25519, secp256r1, secp384r1, secp521r1
    ...ext(0x000a, [...u16(8), ...u16(0x001d), ...u16(0x0017), ...u16(0x0018), ...u16(0x0019)]),
    // ec_point_formats: uncompressed
    ...ext(0x000b, [0x01, 0x00]),
    // signature_algorithms
    ...ext(0x000d, (() => {
      const algs = [0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601, 0x0603, 0x0201];
      return [...u16(algs.length * 2), ...algs.flatMap(u16)];
    })()),
  ];
  const body = [
    0x03, 0x03,                                  // client_version: TLS 1.2
    ...rnd,
    0x00,                                        // session_id: none
    ...u16(CIPHER_SUITES.length * 2), ...CIPHER_SUITES.flatMap(u16),
    0x01, 0x00,                                  // compression: null only
    ...u16(extensions.length), ...extensions,
  ];
  const handshake = [0x01, ...u24(body.length), ...body];
  return Uint8Array.from([0x16, 0x03, 0x01, ...u16(handshake.length), ...handshake]);
}

// ---------------------------------------------------------------------------
// Server flight
// ---------------------------------------------------------------------------

const ALERTS: Record<number, string> = {
  10: "unexpected_message", 40: "handshake_failure", 42: "bad_certificate", 47: "illegal_parameter",
  70: "protocol_version", 71: "insufficient_security", 80: "internal_error", 86: "inappropriate_fallback",
  90: "user_canceled", 109: "missing_extension", 112: "unrecognized_name", 120: "no_application_protocol",
};

const VERSIONS: Record<number, string> = { 0x0300: "SSL 3.0", 0x0301: "TLS 1.0", 0x0302: "TLS 1.1", 0x0303: "TLS 1.2" };

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

export type Flight =
  | { kind: "certificate"; version: string; chain: Uint8Array[] }
  | { kind: "alert"; description: string }
  | { kind: "more" };

/**
 * Looks at everything received so far. Returns the certificate chain once the Certificate message is
 * complete, an alert if the server sent one, and "more" while it is still arriving. Throws on bytes that
 * cannot be TLS.
 */
export function readFlight(received: Uint8Array): Flight {
  let off = 0;
  let hs: Uint8Array = new Uint8Array(0);
  while (received.length - off >= 5) {
    const type = received[off];
    const len = (received[off + 3] << 8) | received[off + 4];
    if (type !== 0x14 && type !== 0x15 && type !== 0x16 && type !== 0x17) throw new Error("not a TLS record");
    if (len > 16640) throw new Error("record too long");
    if (received.length - off - 5 < len) break;
    const payload = received.subarray(off + 5, off + 5 + len);
    if (type === 0x15) {
      const code = payload[1] ?? 0;
      return { kind: "alert", description: ALERTS[code] ?? `alert_${code}` };
    }
    if (type === 0x16) hs = concat(hs, payload);
    off += 5 + len;
  }
  let version = "unknown";
  let p = 0;
  while (hs.length - p >= 4) {
    const t = hs[p];
    const l = (hs[p + 1] << 16) | (hs[p + 2] << 8) | hs[p + 3];
    if (hs.length - p - 4 < l) break;
    const body = hs.subarray(p + 4, p + 4 + l);
    if (t === 0x02 && body.length >= 2) version = VERSIONS[(body[0] << 8) | body[1]] ?? `0x${((body[0] << 8) | body[1]).toString(16)}`;
    if (t === 0x0b) {
      if (body.length < 3) throw new Error("short Certificate message");
      const listLen = (body[0] << 16) | (body[1] << 8) | body[2];
      if (listLen + 3 > body.length) throw new Error("Certificate list overruns its message");
      const chain: Uint8Array[] = [];
      let q = 3;
      while (q + 3 <= 3 + listLen) {
        const cl = (body[q] << 16) | (body[q + 1] << 8) | body[q + 2];
        q += 3;
        if (q + cl > 3 + listLen) throw new Error("certificate overruns its list");
        chain.push(body.subarray(q, q + cl));
        q += cl;
      }
      return { kind: "certificate", version, chain };
    }
    p += 4 + l;
  }
  return { kind: "more" };
}

// ---------------------------------------------------------------------------
// DER
// ---------------------------------------------------------------------------

type Tlv = { tag: number; hl: number; vs: number; ve: number };

function tlv(b: Uint8Array, o: number, limit = b.length): Tlv {
  if (o + 2 > limit) throw new Error("DER truncated");
  const tag = b[o];
  let l = b[o + 1];
  let hl = 2;
  if (l & 0x80) {
    const n = l & 0x7f;
    if (n === 0 || n > 4 || o + 2 + n > limit) throw new Error("DER length form not supported");
    l = 0;
    for (let i = 0; i < n; i++) l = l * 256 + b[o + 2 + i];
    hl = 2 + n;
  }
  const vs = o + hl;
  const ve = vs + l;
  if (ve > limit) throw new Error("DER value overruns its parent");
  return { tag, hl, vs, ve };
}

function oidString(b: Uint8Array, t: Tlv): string {
  const parts: number[] = [Math.floor(b[t.vs] / 40), b[t.vs] % 40];
  let v = 0;
  for (let i = t.vs + 1; i < t.ve; i++) {
    v = v * 128 + (b[i] & 0x7f);
    if (!(b[i] & 0x80)) { parts.push(v); v = 0; }
  }
  return parts.join(".");
}

function clean(s: string): string {
  return s.replace(/[\u0000-\u001f\u007f-\u009f]/g, "").slice(0, 200);
}

function derString(b: Uint8Array, t: Tlv): string {
  const raw = b.subarray(t.vs, t.ve);
  if (t.tag === 0x0c) return clean(new TextDecoder("utf-8", { fatal: false }).decode(raw));
  if (t.tag === 0x1e) {
    let s = "";
    for (let i = 0; i + 1 < raw.length; i += 2) s += String.fromCharCode((raw[i] << 8) | raw[i + 1]);
    return clean(s);
  }
  let s = "";
  for (let i = 0; i < raw.length; i++) s += String.fromCharCode(raw[i]);
  return clean(s);
}

const NAME_OIDS: Record<string, string> = { "2.5.4.3": "CN", "2.5.4.10": "O", "2.5.4.6": "C", "2.5.4.11": "OU" };

function parseName(b: Uint8Array, name: Tlv): Record<string, string> {
  const out: Record<string, string> = {};
  let p = name.vs;
  while (p < name.ve) {
    const set = tlv(b, p, name.ve);
    let q = set.vs;
    while (q < set.ve) {
      const seq = tlv(b, q, set.ve);
      const oid = tlv(b, seq.vs, seq.ve);
      const val = tlv(b, oid.ve, seq.ve);
      const key = NAME_OIDS[oidString(b, oid)];
      if (key && !(key in out)) out[key] = derString(b, val);
      q = seq.ve;
    }
    p = set.ve;
  }
  return out;
}

function parseTime(b: Uint8Array, t: Tlv): string {
  let s = "";
  for (let i = t.vs; i < t.ve; i++) s += String.fromCharCode(b[i]);
  let m: RegExpMatchArray | null;
  if (t.tag === 0x17) {
    m = s.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?Z$/);
    if (!m) throw new Error("unreadable UTCTime");
    const yy = Number(m[1]);
    return iso(yy >= 50 ? 1900 + yy : 2000 + yy, m[2], m[3], m[4], m[5], m[6] ?? "00");
  }
  if (t.tag === 0x18) {
    m = s.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?Z$/);
    if (!m) throw new Error("unreadable GeneralizedTime");
    return iso(Number(m[1]), m[2], m[3], m[4], m[5], m[6] ?? "00");
  }
  throw new Error("validity is not a time");
}

function iso(y: number, mo: string, d: string, h: string, mi: string, s: string): string {
  const out = `${String(y).padStart(4, "0")}-${mo}-${d}T${h}:${mi}:${s}Z`;
  if (Number.isNaN(Date.parse(out))) throw new Error("impossible date");
  return out;
}

function hex(b: Uint8Array, upper = true): string {
  let s = "";
  for (const x of b) s += x.toString(16).padStart(2, "0");
  return upper ? s.toUpperCase() : s;
}

export async function parseCertificate(der: Uint8Array): Promise<CertInfo> {
  const cert = tlv(der, 0);
  if (cert.tag !== 0x30) throw new Error("certificate is not a SEQUENCE");
  const tbs = tlv(der, cert.vs, cert.ve);
  if (tbs.tag !== 0x30) throw new Error("tbsCertificate is not a SEQUENCE");
  let p = tbs.vs;
  let t = tlv(der, p, tbs.ve);
  if (t.tag === 0xa0) { p = t.ve; t = tlv(der, p, tbs.ve); }          // optional [0] version
  if (t.tag !== 0x02) throw new Error("serial number missing");
  let sv = der.subarray(t.vs, t.ve);
  while (sv.length > 1 && sv[0] === 0) sv = sv.subarray(1);
  const serial = hex(sv);
  p = t.ve;
  t = tlv(der, p, tbs.ve); p = t.ve;                                    // signature algorithm
  const issuerT = tlv(der, p, tbs.ve); p = issuerT.ve;
  const validity = tlv(der, p, tbs.ve); p = validity.ve;
  const nb = tlv(der, validity.vs, validity.ve);
  const na = tlv(der, nb.ve, validity.ve);
  const subjectT = tlv(der, p, tbs.ve); p = subjectT.ve;
  const issuer = parseName(der, issuerT);
  const subject = parseName(der, subjectT);
  const sameName = issuerT.ve - issuerT.vs === subjectT.ve - subjectT.vs
    && der.subarray(issuerT.vs, issuerT.ve).every((x, i) => x === der[subjectT.vs + i]);

  const san: string[] = [];
  let sanTruncated = false;
  t = tlv(der, p, tbs.ve); p = t.ve;                                    // subjectPublicKeyInfo
  while (p < tbs.ve) {
    const x = tlv(der, p, tbs.ve);
    p = x.ve;
    if (x.tag !== 0xa3) continue;                                       // [3] extensions
    const exts = tlv(der, x.vs, x.ve);
    let e = exts.vs;
    while (e < exts.ve) {
      const ext = tlv(der, e, exts.ve);
      e = ext.ve;
      const oid = tlv(der, ext.vs, ext.ve);
      if (oidString(der, oid) !== "2.5.29.17") continue;
      let v = tlv(der, oid.ve, ext.ve);
      if (v.tag === 0x01) v = tlv(der, v.ve, ext.ve);                   // optional critical flag
      const names = tlv(der, v.vs, v.ve);                               // GeneralNames ::= SEQUENCE OF GeneralName
      let g = names.vs;
      while (g < names.ve) {
        const gn = tlv(der, g, names.ve);
        g = gn.ve;
        if (gn.tag !== 0x82) continue;                                   // dNSName
        if (san.length >= MAX_SAN) { sanTruncated = true; continue; }
        san.push(derString(der, gn).toLowerCase());
      }
    }
  }
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", der));
  return {
    subject_cn: subject.CN ?? null,
    issuer_cn: issuer.CN ?? null,
    issuer_org: issuer.O ?? null,
    serial,
    not_before: parseTime(der, nb),
    not_after: parseTime(der, na),
    san,
    san_truncated: sanTruncated,
    self_signed: sameName,
    fingerprint_sha256: hex(digest),
  };
}

// ---------------------------------------------------------------------------
// Sockets
// ---------------------------------------------------------------------------

/** node:net behind the Conn interface. Used when Deno.connect is absent (tools/local-scan runs under Node). */
export async function nodeNetConnect(): Promise<Connect | null> {
  try {
    const net = await import("node:net");
    return (host, port) => new Promise<Conn>((resolve, reject) => {
      const socket = net.connect({ host, port });
      const queue: Uint8Array[] = [];
      let wake: (() => void) | null = null;
      let ended = false;
      const poke = () => { const w = wake; wake = null; if (w) w(); };
      socket.on("data", (d: Uint8Array) => { queue.push(d); poke(); });
      socket.on("end", () => { ended = true; poke(); });
      socket.on("close", () => { ended = true; poke(); });
      socket.on("error", (e: Error) => { if (!ended) { ended = true; poke(); } reject(e); });
      socket.once("connect", () => resolve({
        async read(p: Uint8Array) {
          while (queue.length === 0 && !ended) await new Promise<void>((r) => { wake = r; });
          const d = queue.shift();
          if (!d) return null;
          const n = Math.min(p.length, d.length);
          p.set(d.subarray(0, n));
          if (n < d.length) queue.unshift(d.subarray(n));
          return n;
        },
        async write(p: Uint8Array) { socket.write(p); return p.length; },
        close() { socket.destroy(); },
      }));
    });
  } catch {
    return null;
  }
}

/**
 * The socket the current runtime offers: Deno.connect in the edge function, node:net under Node, null if
 * neither exists (which is then recorded as evidence, not guessed around).
 */
export async function defaultConnect(): Promise<Connect | null> {
  const d = (globalThis as unknown as { Deno?: { connect?: (o: { hostname: string; port: number }) => Promise<Conn> } }).Deno;
  if (d && typeof d.connect === "function") return (hostname, port) => d.connect!({ hostname, port });
  return await nodeNetConnect();
}

// ---------------------------------------------------------------------------
// Reading a certificate off a connection
// ---------------------------------------------------------------------------

export function daysBetween(now: Date, notAfterIso: string): number {
  return Math.floor((Date.parse(notAfterIso) - now.getTime()) / 86_400_000);
}

function unavailable(host: string, port: number, started: number, reason: string, detail: string | null = null): CertReading {
  return { state: "unavailable", host, port, reason, detail: detail ? clean(detail) : null, ms: Date.now() - started };
}

/**
 * Connects, sends the ClientHello, reads until the Certificate message or an alert, and closes. Never
 * throws: every outcome is a CertReading, because the caller writes it as evidence either way.
 */
export async function readCertificate(
  host: string,
  opts: { connect: Connect | null; port?: number; timeoutMs?: number; now?: Date },
): Promise<CertReading> {
  const port = opts.port ?? 443;
  const timeoutMs = opts.timeoutMs ?? 7000;
  const started = Date.now();
  if (!opts.connect) return unavailable(host, port, started, "no_socket_api", "this runtime exposes no raw socket");

  let conn: Conn | null = null;
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; try { conn?.close(); } catch { /* already closed */ } }, timeoutMs);
  try {
    let connectTimer: ReturnType<typeof setTimeout> | undefined;
    try {
      conn = await Promise.race([
        opts.connect(host, port),
        new Promise<never>((_, rej) => { connectTimer = setTimeout(() => rej(new Error("connect timed out")), timeoutMs); }),
      ]);
    } catch (e) {
      return unavailable(host, port, started, timedOut || /timed out/i.test(String(e)) ? "timeout" : "connect_failed", String((e as Error)?.message ?? e));
    } finally {
      clearTimeout(connectTimer);
    }
    if (timedOut) { try { conn.close(); } catch { /* already closed */ } return unavailable(host, port, started, "timeout"); }
    await conn.write(buildClientHello(host));

    let received: Uint8Array = new Uint8Array(0);
    const buf = new Uint8Array(16384);
    for (;;) {
      let n: number | null;
      try { n = await conn.read(buf); } catch (e) {
        return unavailable(host, port, started, timedOut ? "timeout" : "closed_early", String((e as Error)?.message ?? e));
      }
      if (timedOut) return unavailable(host, port, started, "timeout");
      if (n === null || n === 0) return unavailable(host, port, started, "closed_early", "the server closed the connection before sending a certificate");
      received = concat(received, buf.subarray(0, n));
      if (received.length > MAX_FLIGHT_BYTES) return unavailable(host, port, started, "parse_error", "server flight too large");
      let flight: Flight;
      try { flight = readFlight(received); } catch (e) { return unavailable(host, port, started, "parse_error", String((e as Error)?.message ?? e)); }
      if (flight.kind === "more") continue;
      if (flight.kind === "alert") {
        return unavailable(host, port, started, flight.description === "protocol_version" ? "requires_tls13" : "tls_alert", `server sent ${flight.description}`);
      }
      if (flight.chain.length === 0) return unavailable(host, port, started, "no_certificate", "the server sent an empty certificate list");
      try {
        const cert = await parseCertificate(flight.chain[0]);
        const now = opts.now ?? new Date();
        return { state: "ok", host, port, tls_version: flight.version, chain_length: flight.chain.length, cert, days_remaining: daysBetween(now, cert.not_after), ms: Date.now() - started };
      } catch (e) {
        return unavailable(host, port, started, "parse_error", String((e as Error)?.message ?? e));
      }
    }
  } finally {
    clearTimeout(timer);
    try { conn?.write(Uint8Array.from([0x15, 0x03, 0x03, 0x00, 0x02, 0x01, 0x00])).catch(() => {}); } catch { /* best effort close_notify */ }
    try { conn?.close(); } catch { /* already closed */ }
  }
}

// ---------------------------------------------------------------------------
// Findings
// ---------------------------------------------------------------------------

function day(iso: string): string { return iso.slice(0, 10); }

/**
 * SEC-023 when the certificate the server presented has passed its notAfter; SEC-024 when it has 14 days
 * or fewer left (high at 7 or fewer). An unavailable reading raises nothing: "could not read it" is not a
 * statement about the certificate, and it is recorded as evidence instead.
 */
export function evaluateCertificate(input: { host: string; reading: CertReading; now: Date; evidenceKey: string }): CertFinding[] {
  const { host, reading, now, evidenceKey } = input;
  if (reading.state !== "ok") return [];
  const days = daysBetween(now, reading.cert.not_after);
  const scope = `Read from the certificate the server presented for ${host} on port 443 during this scan; other host names under the same domain have their own certificates and were not read.`;
  if (days < 0) {
    const ago = -days;
    return [{
      rule_id: SEC_CERT_EXPIRED, severity: "critical",
      title: "The site's TLS certificate has expired",
      detail: `The certificate presented for ${host} expired on ${day(reading.cert.not_after)}, ${ago} day${ago === 1 ? "" : "s"} ago (issued by ${reading.cert.issuer_org ?? reading.cert.issuer_cn ?? "an unnamed authority"}). Browsers block or show a full-page warning for a site whose certificate has expired. ${scope}`,
      location: `tls:${host}`, confidence: "high", evidence_keys: [evidenceKey],
    }];
  }
  if (days <= EXPIRING_DAYS) {
    return [{
      rule_id: SEC_CERT_EXPIRING, severity: days <= EXPIRING_HIGH_DAYS ? "high" : "medium",
      title: days === 0 ? "The site's TLS certificate expires today" : `The site's TLS certificate expires in ${days} day${days === 1 ? "" : "s"}`,
      detail: `The certificate presented for ${host} is valid until ${day(reading.cert.not_after)} (issued by ${reading.cert.issuer_org ?? reading.cert.issuer_cn ?? "an unnamed authority"}). Certificates from automated authorities are normally renewed with about 30 days left, so ${EXPIRING_DAYS} or fewer usually means renewal has already been failing. When it expires, browsers will block or warn on the site. ${scope}`,
      location: `tls:${host}`, confidence: "high", evidence_keys: [evidenceKey],
    }];
  }
  return [];
}

/** The evidence excerpt: small, stable, and JSON so the console can read it back without parsing prose. */
export function certificateEvidence(reading: CertReading): string {
  return JSON.stringify(reading.state === "ok"
    ? {
      state: "ok", host: reading.host, port: reading.port, tls_version: reading.tls_version, chain_length: reading.chain_length,
      days_remaining: reading.days_remaining, cert: reading.cert, ms: reading.ms,
    }
    : { state: "unavailable", host: reading.host, port: reading.port, reason: reading.reason, detail: reading.detail, ms: reading.ms });
}
