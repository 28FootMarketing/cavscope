// legal.ts -- a pure helper for a site's own legal pages: reading the
// governing-law or registered-address US state a site states about itself.
// (PRIV-004, the Terms of Service link check, stays inline in index.ts next
// to PRIV-001, which it mirrors exactly -- an anchor-text/href check has no
// pure logic worth isolating on its own.)
//
// WHY THE STATE MATTERS: muster.q_sitrep_jurisdiction picks which state-level
// statutes (PA Act 35, etc.) a SITREP's jurisdiction section names, and until
// this module it read that state from the SCANNING WORKSPACE's own
// organizations.region_code -- fine for a real tenant scanning its own site,
// wrong for every ad-hoc URL parked in the admin sandbox org, which shares
// ONE region_code (PA, After Today LLC's own state) across every site anyone
// has ever pointed the "Run a URL scan" button at. A YMCA in Hanover, PA and
// a plan-sync SaaS with no stated PA presence at all got the same PA Act 35
// citation, because nothing had ever asked what state the SITE ITSELF claims.
//
// This module only ever reads a state the page states about itself -- a
// governing-law clause, or a postal address -- and never guesses or defaults.
// No match is `code: null`, and callers must treat that as "not determined",
// not as "same state as whoever is asking."

export interface StateSignal {
  code: string | null;
  name: string | null;
  reason: string;
}

const US_STATE_NAMES: Record<string, string> = {
  alabama: "AL", alaska: "AK", arizona: "AZ", arkansas: "AR", california: "CA",
  colorado: "CO", connecticut: "CT", delaware: "DE", florida: "FL", georgia: "GA",
  hawaii: "HI", idaho: "ID", illinois: "IL", indiana: "IN", iowa: "IA",
  kansas: "KS", kentucky: "KY", louisiana: "LA", maine: "ME", maryland: "MD",
  massachusetts: "MA", michigan: "MI", minnesota: "MN", mississippi: "MS",
  missouri: "MO", montana: "MT", nebraska: "NE", nevada: "NV",
  "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY",
  "north carolina": "NC", "north dakota": "ND", ohio: "OH", oklahoma: "OK",
  oregon: "OR", pennsylvania: "PA", "rhode island": "RI", "south carolina": "SC",
  "south dakota": "SD", tennessee: "TN", texas: "TX", utah: "UT", vermont: "VT",
  virginia: "VA", washington: "WA", "west virginia": "WV", wisconsin: "WI",
  wyoming: "WY", "district of columbia": "DC",
};
const US_STATE_CODES = new Set(Object.values(US_STATE_NAMES));

// A state named in <meta name="description"> is a materially weaker signal
// than a governing-law clause or a postal address -- both of those are the
// site making a factual or legal claim about where it IS; a meta description
// is ad copy, and "Central Alabama wedding officiant" states a service area,
// which is usually but not always the same as a legal home. It is read last,
// and only as a full state name (never a bare two-letter code -- "in AL" is
// far too easy to mistake for an unrelated abbreviation in marketing copy).
function metaDescription(html: string): string | null {
  const tag = [...html.matchAll(/<meta\b[^>]*>/gi)].find((m) => /\bname\s*=\s*["']description["']/i.test(m[0]));
  if (!tag) return null;
  const content = tag[0].match(/\bcontent\s*=\s*["']([^"']*)["']/i);
  return content ? content[1] : null;
}

// Reads a US state a page states about ITSELF. Tries a governing-law clause
// first, since that is the site making a legal statement about which state's
// law applies; then a postal address in the page (typically a footer); then,
// weakest, a full state name in the meta description. Returns null for both
// fields on no match -- this never guesses.
export function extractUsState(html: string): StateSignal {
  const plain = html.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ");

  const governed = plain.match(
    /govern(?:ed|ing)\s+by\s+(?:the\s+)?laws?\s+of\s+(?:the\s+state\s+of\s+|the\s+commonwealth\s+of\s+)?([a-z]+(?:\s+[a-z]+){0,2})(?=[.,;]|\s+and\b|\s+without\b|$)/i,
  );
  if (governed) {
    const raw = governed[1].trim().toLowerCase();
    const code = US_STATE_NAMES[raw];
    if (code) return { code, name: raw, reason: `Governing-law clause: "...${governed[0].trim()}".` };
  }

  const addr = plain.match(/,\s*([A-Z]{2})\s+\d{5}(?:-\d{4})?\b/);
  if (addr && US_STATE_CODES.has(addr[1])) {
    return { code: addr[1], name: null, reason: `Postal address in page text: "${addr[0].trim()}".` };
  }

  const desc = metaDescription(html);
  if (desc) {
    // "Washington, D.C." names the federal district, not the state of
    // Washington -- checked before the general name loop, which would
    // otherwise match the word "Washington" inside it and report WA.
    if (/\bwashington,?\s*d\.?\s*c\.?\b/i.test(desc)) {
      return { code: "DC", name: "district of columbia", reason: `Meta description: "${desc.slice(0, 160)}".` };
    }
    for (const [name, code] of Object.entries(US_STATE_NAMES)) {
      if (new RegExp(`\\b${name.replace(/ /g, "\\s+")}\\b`, "i").test(desc)) {
        return { code, name, reason: `Meta description: "${desc.slice(0, 160)}".` };
      }
    }
  }

  return { code: null, name: null, reason: "No governing-law clause, US postal address or meta-description state name found." };
}
