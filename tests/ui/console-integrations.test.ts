// Integrations section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-integrations.test.ts
//
// The header said every row was inferred from real rows; two were fixed text, and one of them
// ("subscription.deleted: not handled", in red) had been false since cancellation was handled.
// The Stripe row said "handled" in green with zero paid checkouts ever recorded.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const mig = readFileSync(join(root, "supabase/migrations/20261010201243_admin_console_integrations_payload.sql"), "utf8");
const page = html.slice(html.indexOf("function renderIntegrations()"), html.indexOf("function platformAgents()"));

test("no row is fixed text: every row is built from the integrations payload", () => {
  assert.match(page, /const I = DATA\.integrations \|\| \{\}/);
  assert.doesNotMatch(page, /not handled/);
  assert.doesNotMatch(page, /<span class="status-val">handled<\/span>/);
});

test("zero recorded checkouts is not shown as healthy", () => {
  assert.match(page, /st\.grants > 0 \? 'ok' : 'warn'/);
  assert.match(page, /none recorded yet/);
});

test("a cancellation never seen is said to be never observed, not 'not handled'", () => {
  assert.match(page, /handled in code · never observed/);
});

test("a failed forward, an undelivered support request and an erroring tenant LLM are red", () => {
  assert.match(page, /ib\.failed > 0 \? 'bad'/);
  assert.match(page, /sp\.failed > 0 \? 'bad'/);
  assert.match(page, /ll\.erroring > 0 \? 'bad'/);
});

test("the payload returns what each row reads", () => {
  for (const k of ["stripe", "email", "inbound", "support", "tenant_llms", "browser"]) {
    assert.ok(mig.includes(`''${k}''`), `payload lacks ${k}`);
  }
  assert.match(mig, /expected exactly 1 match/);
});
