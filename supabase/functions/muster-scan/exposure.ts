// SEC-016: sensitive file or directory exposure.
//
// STUB -- not wired into index.ts. See supabase/migrations/
// 20260923190000_muster_084_hardening_gap_rules_inactive.sql for what has to
// happen before SEC-016 may be set active: index.ts has to fetch each probe
// path, hand the results in here, and ENGINE_VERSION has to move past
// http-native-1.7.1 and be observed live. Read that migration's header
// before touching this file's activation status.
//
// Pure, like login.ts's admin-console probes, which this deliberately
// mirrors: a plain GET, judged on the body matching that product's own
// signature, never on the status code alone. A single-page app or a
// catch-all 404 page answers every path with 200, so a status-code-only
// check would accuse every such site of leaking its .git directory. That is
// exactly the failure AUTH-004/AUTH-005 already guard against, and this rule
// reuses the guard rather than reinventing a weaker one.
//
// Deliberately excluded from the probe list: /config.json and similar
// generically-named files. Too many frameworks legitimately serve a
// non-secret config.json at that path, and a hit rate dominated by false
// positives costs more credibility than the rule is worth -- the same
// reasoning SEC-014 uses to exclude tag-manager scripts from Subresource
// Integrity.

export type Severity = "critical" | "high" | "medium" | "low" | "info";

export type ExposureFinding = {
  rule_id: string;
  severity: Severity;
  title: string;
  detail: string;
  location: string;
  confidence: "high" | "medium" | "low";
  evidence_keys: string[];
};

export type ExposureProbe = {
  path: string;
  /** What kind of thing this path exposes, for the finding text. */
  label: string;
  /** True only when the body is recognisably this path's own content, not a fallback page. */
  matches: (body: string) => boolean;
};

/**
 * Each probe is a plain GET to a path that should never resolve on a
 * correctly configured server, confirmed by a content signature rather than
 * a status code. Kept short and specific on purpose: every entry here is a
 * claim that a particular byte pattern only appears when the real file is
 * being served, and that claim is only made for patterns distinctive enough
 * to not occur in an ordinary 200 response.
 */
export const EXPOSURE_PROBES: ExposureProbe[] = [
  {
    path: "/.git/config",
    label: "a Git repository (.git/config)",
    matches: (b) => /\[core\]/i.test(b) && /repositoryformatversion/i.test(b),
  },
  {
    path: "/.git/HEAD",
    label: "a Git repository (.git/HEAD)",
    matches: (b) => /^ref:\s*refs\//i.test(b.trim()),
  },
  {
    path: "/.env",
    label: "an environment file (.env)",
    // Requires more than one KEY=VALUE line so a plain-text page that
    // happens to contain a single "A=B" somewhere is not mistaken for it.
    matches: (b) => (b.match(/^[A-Z][A-Z0-9_]*=.*/gm) ?? []).length >= 2,
  },
  {
    path: "/.DS_Store",
    label: "a macOS Finder metadata file (.DS_Store)",
    // The format's own magic bytes: a 4-byte 0x00000001 header followed by
    // the literal "Bud1" magic string, present in every real .DS_Store.
    matches: (b) => b.includes("Bud1") && b.slice(0, 8).includes("\x00\x00\x00\x01"),
  },
  {
    path: "/backup.sql",
    label: "a database backup (backup.sql)",
    matches: (b) => /-- mysql dump/i.test(b) || /^create table/im.test(b) || /^insert into/im.test(b),
  },
  {
    path: "/dump.sql",
    label: "a database backup (dump.sql)",
    matches: (b) => /-- mysql dump/i.test(b) || /^create table/im.test(b) || /^insert into/im.test(b),
  },
  {
    path: "/.aws/credentials",
    label: "an AWS credentials file (.aws/credentials)",
    matches: (b) => /\[default\]/i.test(b) && /aws_access_key_id\s*=/i.test(b),
  },
  {
    path: "/wp-config.php.bak",
    label: "a WordPress configuration backup (wp-config.php.bak)",
    matches: (b) => /define\s*\(\s*['"]DB_PASSWORD['"]/i.test(b),
  },
];

export type ExposureProbeResult = {
  probe: ExposureProbe;
  /** Final URL after same-site redirects, or null when the request left the site. */
  finalUrl: string | null;
  status: number | null;
  body: string;
};

/** Whether a probe found the real file, on this site, at its own path. */
export function exposureHit(r: ExposureProbeResult): boolean {
  return r.finalUrl !== null && r.status === 200 && r.probe.matches(r.body);
}

export function evaluateExposure(input: {
  results: ExposureProbeResult[];
  evidenceKey: string;
}): ExposureFinding[] {
  const hits = input.results.filter(exposureHit);
  if (hits.length === 0) return [];

  const items = hits.map((h) => `${h.probe.label} at ${h.finalUrl}`);
  return [{
    rule_id: "SEC-016",
    severity: "high",
    title: "Sensitive file or directory exposed",
    detail: `${hits.length} sensitive path(s) are publicly reachable and served their real content, not a fallback page: ${items.join("; ")}. These commonly contain credentials, connection strings, or enough of the application's source to plan a further attack.`,
    location: hits.map((h) => h.probe.path).join(", "),
    confidence: "high",
    evidence_keys: [input.evidenceKey],
  }];
}
