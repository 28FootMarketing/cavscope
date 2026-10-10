// Support Access section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-support-access.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const mig = readFileSync(join(root, "supabase/migrations/20261010191001_support_access_notify_all_orgs_and_close_expired.sql"), "utf8");

test("the page claims no more than the database does", () => {
  assert.doesNotMatch(html, /Every impersonation session ever opened/);
  assert.match(html, /The 25 most recent impersonation sessions/);
  assert.match(html, /every organization this user belongs to/);
  assert.match(html, /id="impReason" minlength="10" maxlength="500"/);
});

test("migration: every membership is told, lapsed sessions are closed with an end notice, reason is capped", () => {
  assert.match(mig, /from cavscope\.organization_members om\s+where om\.user_id = p_target/);
  assert.match(mig, /ended_reason = 'expired'/);
  assert.match(mig, /session_ended/);
  assert.match(mig, /500 characters or fewer/);
  assert.match(mig, /revoke all on function cavscope\.close_expired_impersonations\(\) from public, anon, authenticated/);
  assert.match(mig, /expected exactly 1 match/);
});
