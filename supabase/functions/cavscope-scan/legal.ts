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
// governing-law clause, a JSON-LD or printed postal address, or a state named
// in the meta description -- and never guesses or defaults.
// No match is `code: null`, and callers must treat that as "not determined",
// not as "same state as whoever is asking."

import { jsonLdEntities } from "./aio.ts";

// Which signal a detection came from, strongest first. Stored with the state
// (websites.detected_region_basis) so a report can say how much weight its
// location deserves: a governing-law clause is the site making a legal claim;
// a meta description is ad copy.
export type StateBasis = "governing_law" | "jsonld_address" | "postal_address" | "meta_description";

export interface StateSignal {
  code: string | null;
  name: string | null;
  basis: StateBasis | null;
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

const US_COUNTRY = new Set(["us", "usa", "u.s.", "u.s.a.", "united states", "united states of america"]);

function usStateCode(value: string): string | null {
  const v = value.trim();
  if (US_STATE_CODES.has(v.toUpperCase())) return v.toUpperCase();
  return US_STATE_NAMES[v.toLowerCase()] ?? null;
}

// The organization's own postal address, as its structured data declares it:
// `address.addressRegion` on a top-level or @graph entity. Deliberately NOT
// `areaServed` -- that is where a business works, not where it is, and is the
// same weak kind of signal as a meta description. An address whose
// addressCountry names somewhere other than the US is skipped rather than
// read as a US state.
function jsonLdState(html: string): { code: string; region: string } | null {
  for (const e of jsonLdEntities(html)) {
    const addrs = Array.isArray(e.address) ? e.address : [e.address];
    for (const a of addrs) {
      if (!a || typeof a !== "object" || Array.isArray(a)) continue;
      const o = a as Record<string, unknown>;
      const c = o.addressCountry;
      const country = typeof c === "string" ? c
        : c && typeof c === "object" ? String((c as Record<string, unknown>).name ?? "") : "";
      if (country.trim() && !US_COUNTRY.has(country.trim().toLowerCase())) continue;
      if (typeof o.addressRegion !== "string") continue;
      const code = usStateCode(o.addressRegion);
      if (code) return { code, region: o.addressRegion };
    }
  }
  return null;
}

// Reads a US state a page states about ITSELF, strongest signal first: a
// governing-law clause (the site making a legal statement about which state's
// law applies); the postal address in its JSON-LD (structured, and explicitly
// the organization's own); a postal address in the page text (typically a
// footer, though it could be any address the page prints); then, weakest, a
// full state name in the meta description. Returns null on no match -- this
// never guesses.
export function extractUsState(html: string): StateSignal {
  const plain = html.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ");

  const governed = plain.match(
    /govern(?:ed|ing)\s+by\s+(?:the\s+)?laws?\s+of\s+(?:the\s+state\s+of\s+|the\s+commonwealth\s+of\s+)?([a-z]+(?:\s+[a-z]+){0,2})(?=[.,;]|\s+and\b|\s+without\b|$)/i,
  );
  if (governed) {
    const raw = governed[1].trim().toLowerCase();
    const code = US_STATE_NAMES[raw];
    if (code) return { code, name: raw, basis: "governing_law", reason: `Governing-law clause: "...${governed[0].trim()}".` };
  }

  const ld = jsonLdState(html);
  if (ld) return { code: ld.code, name: null, basis: "jsonld_address", reason: `JSON-LD postal address: addressRegion "${ld.region}".` };

  const addr = plain.match(/,\s*([A-Z]{2})\s+\d{5}(?:-\d{4})?\b/);
  if (addr && US_STATE_CODES.has(addr[1])) {
    return { code: addr[1], name: null, basis: "postal_address", reason: `Postal address in page text: "${addr[0].trim()}".` };
  }

  const desc = metaDescription(html);
  if (desc) {
    // "Washington, D.C." names the federal district, not the state of
    // Washington -- checked before the general name loop, which would
    // otherwise match the word "Washington" inside it and report WA.
    if (/\bwashington,?\s*d\.?\s*c\.?\b/i.test(desc)) {
      return { code: "DC", name: "district of columbia", basis: "meta_description", reason: `Meta description: "${desc.slice(0, 160)}".` };
    }
    for (const [name, code] of Object.entries(US_STATE_NAMES)) {
      // Several state names are also common surnames or given names
      // (Washington, Georgia, Virginia). A name followed by a generational
      // suffix -- "Anthony Washington Sr.", live on anthonywashingtonsr.com's
      // own /about page and the reason this exclusion exists -- is
      // unambiguously a person, never a place, so it is excluded here
      // rather than credited as that state. This is a targeted guard for a
      // confirmed failure, not exhaustive protection against every possible
      // name collision: "Denzel Washington" with no suffix still matches.
      const re = new RegExp(`\\b${name.replace(/ /g, "\\s+")}\\b(?!\\s+(?:Sr|Jr|II|III|IV)\\.?\\b)`, "i");
      if (re.test(desc)) {
        return { code, name, basis: "meta_description", reason: `Meta description: "${desc.slice(0, 160)}".` };
      }
    }
  }

  return { code: null, name: null, basis: null, reason: "No governing-law clause, JSON-LD address, US postal address or meta-description state name found." };
}
