// SEC-016 rule logic, tested against the shipped module.
//
//   node --experimental-strip-types --test tests/scan/exposure.test.ts
//
// Wired into index.ts's login-surface section (5c) as of ENGINE_VERSION
// http-native-1.8.0. Held inactive in muster.scan_rules until a scan reports
// that version live -- see supabase/migrations/
// 20260923190000_muster_086_hardening_gap_rules_inactive.sql.
//
// The failure mode that matters most here is the one AUTH-004/AUTH-005
// already guard against: a catch-all 404 page, or a single-page app that
// answers every path with 200, must never be accused of leaking a .git
// directory. Every probe's `matches` function is tested against both its real
// signature and a plausible fallback-page body that happens to return 200.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  EXPOSURE_PROBES,
  evaluateExposure,
  exposureHit,
  type ExposureProbeResult,
} from "../../supabase/functions/muster-scan/exposure.ts";

function probe(path: string) {
  const p = EXPOSURE_PROBES.find((x) => x.path === path);
  if (!p) throw new Error(`no probe registered for ${path}`);
  return p;
}

const FALLBACK_PAGE = "<!doctype html><html><body><h1>Not Found</h1><p>This single-page app serves the same shell for every path.</p></body></html>";

// --- probe signatures --------------------------------------------------------

test(".git/config matches a real Git config, not a fallback page", () => {
  const real = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n[remote \"origin\"]\n\turl = git@example.com:x/y.git\n";
  assert.equal(probe("/.git/config").matches(real), true);
  assert.equal(probe("/.git/config").matches(FALLBACK_PAGE), false);
});

test(".git/HEAD matches only a real ref line", () => {
  assert.equal(probe("/.git/HEAD").matches("ref: refs/heads/main\n"), true);
  assert.equal(probe("/.git/HEAD").matches("  ref: refs/heads/main  "), true);
  assert.equal(probe("/.git/HEAD").matches(FALLBACK_PAGE), false);
});

test(".env requires more than one KEY=VALUE line, so a page with one incidental match does not count", () => {
  const real = "DB_PASSWORD=hunter2\nSTRIPE_SECRET_KEY=sk_live_abc\nAPP_ENV=production\n";
  assert.equal(probe("/.env").matches(real), true);
  assert.equal(probe("/.env").matches("Just a page that mentions A=B once."), false);
  assert.equal(probe("/.env").matches(FALLBACK_PAGE), false);
});

test(".DS_Store matches its magic bytes, not a page that happens to contain the string Bud1", () => {
  const real = "\x00\x00\x00\x01Bud1" + "\x00".repeat(20);
  assert.equal(probe("/.DS_Store").matches(real), true);
  assert.equal(probe("/.DS_Store").matches("a blog post that mentions Bud1 the dog"), false);
});

test("backup.sql and dump.sql match a MySQL dump header or DDL/DML, not prose", () => {
  for (const path of ["/backup.sql", "/dump.sql"]) {
    assert.equal(probe(path).matches("-- MySQL dump 10.13  Distrib 8.0.34"), true);
    assert.equal(probe(path).matches("CREATE TABLE `users` (\n  id INT\n);"), true);
    assert.equal(probe(path).matches("INSERT INTO `users` VALUES (1,'a');"), true);
    assert.equal(probe(path).matches("A backup was scheduled for tonight."), false);
  }
});

test(".aws/credentials matches the ini-style profile format", () => {
  const real = "[default]\naws_access_key_id = AKIAABCDEF\naws_secret_access_key = abc123\n";
  assert.equal(probe("/.aws/credentials").matches(real), true);
  assert.equal(probe("/.aws/credentials").matches("[default] is a great name for a profile"), false);
});

test("wp-config.php.bak matches WordPress's DB_PASSWORD define", () => {
  const real = "<?php\ndefine('DB_PASSWORD', 'hunter2');\ndefine('DB_USER', 'wp');\n";
  assert.equal(probe("/wp-config.php.bak").matches(real), true);
  assert.equal(probe("/wp-config.php.bak").matches(FALLBACK_PAGE), false);
});

// --- exposureHit --------------------------------------------------------

test("exposureHit is false when the probe left the site (finalUrl null), even if the body matches", () => {
  const r: ExposureProbeResult = { probe: probe("/.git/config"), finalUrl: null, status: 200, body: "[core]\nrepositoryformatversion = 0" };
  assert.equal(exposureHit(r), false);
});

test("exposureHit is false on a non-200 status even with a matching body", () => {
  const r: ExposureProbeResult = { probe: probe("/.git/HEAD"), finalUrl: "https://example.com/.git/HEAD", status: 403, body: "ref: refs/heads/main" };
  assert.equal(exposureHit(r), false);
});

test("exposureHit is true only for a same-site 200 with a matching body", () => {
  const r: ExposureProbeResult = { probe: probe("/.git/HEAD"), finalUrl: "https://example.com/.git/HEAD", status: 200, body: "ref: refs/heads/main" };
  assert.equal(exposureHit(r), true);
});

// --- evaluateExposure --------------------------------------------------------

test("evaluateExposure raises nothing when no probe hit", () => {
  const results: ExposureProbeResult[] = EXPOSURE_PROBES.map((p) => ({ probe: p, finalUrl: "https://example.com" + p.path, status: 404, body: "not found" }));
  assert.deepEqual(evaluateExposure({ results, evidenceKey: "exposure_discovery" }), []);
});

test("evaluateExposure raises one SEC-016 finding naming every hit", () => {
  const results: ExposureProbeResult[] = [
    { probe: probe("/.git/HEAD"), finalUrl: "https://example.com/.git/HEAD", status: 200, body: "ref: refs/heads/main" },
    { probe: probe("/.env"), finalUrl: "https://example.com/.env", status: 200, body: "DB_PASSWORD=x\nAPP_ENV=production" },
    { probe: probe("/.aws/credentials"), finalUrl: null, status: 200, body: "[default]\naws_access_key_id = x" }, // left the site: excluded
  ];
  const out = evaluateExposure({ results, evidenceKey: "exposure_discovery" });
  assert.equal(out.length, 1);
  assert.equal(out[0].rule_id, "SEC-016");
  assert.equal(out[0].severity, "high");
  assert.equal(out[0].evidence_keys[0], "exposure_discovery");
  assert.match(out[0].detail, /\.git\/HEAD/);
  assert.match(out[0].detail, /\.env/);
  assert.doesNotMatch(out[0].detail, /aws\/credentials/); // the off-site hit must not be counted
  assert.equal(out[0].location.includes("/.aws/credentials"), false);
});
