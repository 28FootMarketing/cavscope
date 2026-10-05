// The alert email's "View full detail" link comes from cavscope.autotriage(), whose latest definition
// wins. It kept naming app.muster.partners after the rename because the earlier cleanup searched for
// the word MUSTER, not for the host. This pins the LATEST definition, not any one migration.
//
//   node --experimental-strip-types --test tests/migrations/no-old-host-in-alerts.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "supabase", "migrations");
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();

test("the newest migration that rewrites autotriage points the alert link at the CavScope host", () => {
  const rewriters = files.filter((f) => /create or replace function cavscope\.autotriage|replace\(d, '[^']*', '[^']*'\)/i.test(readFileSync(join(dir, f), "utf8")) && /autotriage/.test(readFileSync(join(dir, f), "utf8")));
  const latest = rewriters[rewriters.length - 1];
  const sql = readFileSync(join(dir, latest), "utf8");
  assert.match(sql, /https:\/\/cavscope\.28footsystems\.com\/app#risks/, `${latest} sets the new link`);
  assert.match(latest, /round_two/, "the round-two migration is the latest to touch it");
});

test("round two rewrites the stored alert history and the visible leftovers", () => {
  const sql = readFileSync(join(dir, files.find((f) => f.includes("round_two"))!), "utf8");
  for (const needle of ["notification_outbox", "brand_profiles", "jurisdictions", "remediation_actions", "pricing_settings"]) {
    assert.ok(sql.includes(needle), `${needle} is rewritten`);
  }
});
