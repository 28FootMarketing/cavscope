/**
 * Availability classification: telling "nothing answered" apart from
 * "something answered and we could not read it".
 *
 * AVAIL-001 says "Site unreachable or returning an error" and its plain-English
 * line says "Visitors cannot load the site." For a host that is serving pages to
 * browsers, every word of that is false -- the same failure AVAIL-003 was added
 * for, arriving through a different door.
 *
 * hpsd.k12.pa.us is the case that found it. The engine's HTTPS request came back
 * as `client error (SendRequest): invalid HTTP header parsed`, which AVAIL-001
 * reported as a critical outage on a site that loads normally in a browser and
 * returned HTTP 200 to a lenient client in the same minute. The plain-HTTP HEAD
 * probe to the same host answered 200 as well, in the same scan, while the
 * report said the site was unreachable.
 *
 * The distinction is not a guess. hyper raises these errors only after response
 * bytes have been received and failed parsing: a refused connection, a DNS
 * failure and a TLS handshake failure all produce different messages, because
 * they happen before any response exists. So a match here is positive evidence
 * that a server answered -- which makes "unreachable" the wrong word, and makes
 * the failure worth reporting on its own terms instead.
 *
 * The list is deliberately tight. Anything not named here stays on AVAIL-001,
 * because the cost of this classifier being wrong in that direction is hiding a
 * real outage, which is worse than the defect it fixes.
 */

/**
 * Error substrings that can only be produced after a response has arrived and
 * failed HTTP parsing. Matched case-insensitively against the raw client error.
 *
 * Deliberately excluded: "connection closed before message completed", which is
 * also what a mid-response reset or an origin crash looks like. A truncated
 * response is an outage symptom, not a conformance one.
 */
const RESPONSE_PARSE_MARKERS = [
  "invalid http header",
  "invalid header name",
  "invalid header value",
  "invalid http version",
  "invalid status line",
  "invalid chunk size",
  "invalid content-length",
  "message head is too large",
] as const;

/**
 * True when the client failed while parsing a response the server had already
 * begun sending -- the host is up, and the scan is unassessed rather than the
 * site being down.
 */
export function responseRejectedByClient(error: string | null | undefined): boolean {
  if (!error) return false;
  const e = error.toLowerCase();
  return RESPONSE_PARSE_MARKERS.some((m) => e.includes(m));
}

export const RESPONSE_PARSE_MARKER_LIST: readonly string[] = RESPONSE_PARSE_MARKERS;
