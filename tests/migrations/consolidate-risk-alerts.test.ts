// A scan that opens several critical/high risks at once used to queue one
// notification_outbox row -- and one email -- per risk. Anthony asked for
// these to be one email per scan run, not several: see migration
// muster_119_consolidate_risk_opened_alerts_per_org.
//
//   node --experimental-strip-types --test tests/migrations/consolidate-risk-alerts.test.ts
//
// Matches both the muster.autotriage(...) and cavscope.autotriage() forms the
// function has been defined under across migration history (see
// tests/migrations/cta-deep-link.test.ts's header for why) and picks the file
// that is actually newest by filename, which sorts correctly either way since
// every migration filename is timestamp-prefixed.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const migrationsDir = join(repoRoot, "supabase", "migrations");

function newestAutotriageBody(): string {
  const files = readdirSync(migrationsDir)
    .filter((f) => f.endsWith(".sql"))
    .filter((f) => /create or replace function (muster|cavscope)\.autotriage\(/i.test(
      readFileSync(join(migrationsDir, f), "utf8"),
    ))
    .sort();
  assert.ok(files.length > 0, "no migration defines autotriage()");
  const sql = readFileSync(join(migrationsDir, files[files.length - 1]), "utf8");
  const start = sql.search(/create or replace function (muster|cavscope)\.autotriage\(/i);
  const end = sql.indexOf("$function$\n;", start);
  assert.ok(start >= 0 && end > start, `could not isolate autotriage's body in ${files[files.length - 1]}`);
  return sql.slice(start, end);
}

test("newly-opened critical/high risks are grouped into one batch per organization, not queued per risk", () => {
  const body = newestAutotriageBody();
  // Risks accumulate into a jsonb array during the finding loop instead of
  // each inserting its own notification_outbox row immediately.
  assert.match(body, /v_alert_risks := v_alert_risks \|\| jsonb_build_object/);
  // The insert into notification_outbox happens once per group, in a second
  // loop over the grouped batches -- not inside the per-finding loop above it.
  assert.match(body, /group by 1/);
  const insertIndex = body.indexOf("insert into cavscope.notification_outbox");
  const firstLoopEnd = body.indexOf("end loop;");
  assert.ok(insertIndex > firstLoopEnd, "the outbox insert must live in the batch loop, not the per-finding loop");
});

test("the old one-email-per-risk subject and body format are gone", () => {
  const body = newestAutotriageBody();
  assert.ok(
    !body.includes("format('[CavScope] New %s risk on %s: %s'"),
    "the singular per-risk subject format should have been replaced by the batched one",
  );
  assert.ok(
    !body.includes("CavScope opened a new %s-severity risk"),
    "the singular per-risk body format should have been replaced by the batched one",
  );
});

test("the batched subject and body still say CavScope and carry a risk count", () => {
  const body = newestAutotriageBody();
  assert.match(body, /format\('\[CavScope\] %s new %s on %s \(%s\)'/);
  assert.match(body, /CavScope opened %s new %s on %s from the latest scan activity/);
});

test("the batch is anchored to a real, freshly-created risk id, keeping entity_type within its CHECK constraint", () => {
  const body = newestAutotriageBody();
  // notification_outbox.entity_type only allows 'risk' | 'sitrep' | 'organization' | 'website' --
  // there is no 'scan' or 'batch' value, so the batch keys off one real risk id from it.
  assert.match(body, /max\(\(elem->>'risk_id'\)::bigint\) as anchor_risk_id/);
  assert.match(body, /'risk', v_batch\.anchor_risk_id/);
});

test("the CTA deep link into the risk register survives consolidation", () => {
  const body = newestAutotriageBody();
  assert.match(body, /View full detail: https:\/\/app\.muster\.partners\/app#risks\\n/);
});

test("the no-recipient skip is logged once per batch, not once per risk", () => {
  const body = newestAutotriageBody();
  assert.match(body, /'risk', v_batch\.anchor_risk_id, 'alert_skipped_no_recipient'/);
});
