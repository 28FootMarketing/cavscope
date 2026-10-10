// System Health section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-system-health.test.ts
//
// A cron job that calls an edge function reports "succeeded" once the request is queued, so the
// table could read healthy while every call failed; a schedule that was not "every N minutes" was
// judged against 15, so an hourly or daily job would have read as late all the time; and the panel
// heading still counted "muster-* pg_cron jobs".

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const mig = readFileSync(join(root, "supabase/migrations/20261010201548_admin_console_cron_http_responses.sql"), "utf8");

// Pull the two pure helpers out of the page and run them.
const fn = (name: string) => {
  const a = html.indexOf(`function ${name}(`);
  assert.ok(a > 0, `${name} missing`);
  let depth = 0, i = html.indexOf("{", a);
  const start = i;
  for (; i < html.length; i++) {
    if (html[i] === "{") depth++;
    else if (html[i] === "}" && --depth === 0) break;
  }
  return html.slice(a, i + 1);
};
const interval = new Function(`${fn("scheduleIntervalMin")}; return scheduleIntervalMin;`)();
const late = new Function(`${fn("scheduleIntervalMin")}; ${fn("jobIsLate")}; return jobIsLate;`)();

test("the schedules on file are read correctly", () => {
  assert.equal(interval("*/5 * * * *"), 5);
  assert.equal(interval("*/15 * * * *"), 15);
  assert.equal(interval("7,22,37,52 * * * *"), 15);
  assert.equal(interval("0 * * * *"), 60);
  assert.equal(interval("0 3 * * *"), 1440);
});

test("a calendar schedule or an unreadable one is not judged", () => {
  assert.equal(interval("0 3 * * 1"), null);
  assert.equal(interval("garbage"), null);
});

test("a daily job that ran an hour ago is not late; an every-5-minutes job that ran 11 minutes ago is", () => {
  const ago = (min: number) => new Date(Date.now() - min * 60000).toISOString();
  assert.equal(late({ active: true, schedule: "0 3 * * *", last_success_at: ago(60) }), false);
  assert.equal(late({ active: true, schedule: "*/5 * * * *", last_success_at: ago(11) }), true);
  assert.equal(late({ active: true, schedule: "*/5 * * * *", last_success_at: ago(8) }), false);
  assert.equal(late({ active: false, schedule: "*/5 * * * *", last_success_at: ago(1) }), true);
  assert.equal(late({ active: true, schedule: "*/5 * * * *", last_success_at: null }), true);
});

test("the Overview and System Health share one lateness rule", () => {
  assert.match(html, /const stale = cron\.filter\(jobIsLate\)/);
});

test("job calls are shown, and a failure is red", () => {
  assert.match(html, /name: 'Job Calls', state: ch\.failed > 0 \? 'bad'/);
  assert.match(html, /DATA\.cron_http/);
});

test("the heading no longer counts muster-* jobs", () => {
  assert.doesNotMatch(html, /muster-\* pg_cron/);
  assert.doesNotMatch(html, /No muster-\* cron jobs/);
});

test("migration: counts non-2xx/3xx answers and no answer as failures; edit applies once", () => {
  assert.match(mig, /status_code is null or r\.status_code >= 400/);
  assert.match(mig, /expected exactly 1 match/);
});
