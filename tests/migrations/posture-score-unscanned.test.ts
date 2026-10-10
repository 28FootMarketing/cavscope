// A site with no completed scan has no posture score. 100 - 0 findings read as a pass (green) for a
// target the engine never read; posture_score is null until a scan completes, and posture_band(null)
// is null rather than falling through to 'red'.
//
//   node --experimental-strip-types --test tests/migrations/posture-score-unscanned.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const sql = readFileSync(join(root, "supabase/migrations/20261010205339_posture_score_null_when_unscanned.sql"), "utf8")
  .replace(/^--.*$/gm, "");

test("posture_score is null unless a scan on the site is complete", () => {
  assert.match(sql, /function cavscope\.posture_score\(p_website_id bigint\)[\s\S]*?exists \(select 1 from cavscope\.scans s where s\.website_id = p_website_id and s\.status = 'complete'\)[\s\S]*?then cavscope\.posture_score_from_findings/);
});

test("posture_band(null) is null", () => {
  assert.match(sql, /case when p_score is null then null when p_score >= 85/);
});

test("the unguarded formula is closed to browsers and used only by engine_ingest", () => {
  assert.match(sql, /revoke all on function cavscope\.posture_score_from_findings\(bigint\) from public, anon, authenticated/);
  assert.match(sql, /v_score := cavscope\.posture_score_from_findings\(v_scan\.website_id\)/);
});
