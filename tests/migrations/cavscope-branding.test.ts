// Every customer- (and AI-agent-) facing SQL string that names the product
// must say CavScope, not MUSTER. muster/muster_* stays as the internal
// schema/RPC/hostname identifier per CLAUDE.md's brand note -- this guards
// the DISPLAY word only, in the functions that put text in front of a real
// reader: the SITREP itself, its jurisdiction section, the control
// register, the default (non-white-label) report brand, a risk opened from
// a promoted finding, a brand-settings plan-gate error a tenant can see, the
// beta-signup deadline message, and the MCP agent tool catalog.
//
//   node --experimental-strip-types --test tests/migrations/cavscope-branding.test.ts
//
// Two real defects motivated this: muster.autotriage()'s risk_opened email
// still said "[MUSTER] New ... risk" and "MUSTER opened a new risk" months
// after the rebrand (found by sending a real rendered sample and reading
// it), and muster.q_brand() -- what every non-white-labeled SITREP reads its
// product name from -- still returned brand_name 'MUSTER' as the default.
// Fixed in this same session: muster_114 (autotriage) and muster_115
// (q_brand) by retyping the (small) corrected body directly, muster_116 (the
// rest -- generate_sitrep and friends) by muster_016's read-and-replace
// technique, since generate_sitrep alone is 16KB and retyping a body that
// size is exactly what caused the doubled-backslash regression fixed two
// migrations earlier in this same session.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const migrationsDir = join(repoRoot, "supabase", "migrations");

const migrationFiles = readdirSync(migrationsDir).filter((f) => f.endsWith(".sql")).sort();

function newestBody(fnName: string): string {
  const files = migrationFiles.filter((f) =>
    new RegExp(`create or replace function ${fnName.replace(".", "\\.")}\\(`, "i").test(
      readFileSync(join(migrationsDir, f), "utf8"),
    )
  );
  assert.ok(files.length > 0, `no migration defines ${fnName}`);
  const sql = readFileSync(join(migrationsDir, files[files.length - 1]), "utf8");
  const start = sql.search(new RegExp(`create or replace function ${fnName.replace(".", "\\.")}\\(`, "i"));
  const end = sql.indexOf("$function$\n;", start);
  assert.ok(start >= 0 && end > start, `could not isolate ${fnName}'s body in ${files[files.length - 1]}`);
  return sql.slice(start, end);
}

// muster_116 fixed five muster-schema functions and two public RPCs by
// muster_016's technique: read pg_get_functiondef out of the live catalog
// and EXECUTE a string replace, rather than writing a literal
// "create or replace function ... $function$...$function$" body into the
// migration file. That means there is no file text anywhere in this repo
// showing the corrected bodies of those functions -- the correction exists
// only in the live database. newestBody()'s literal-text search would find
// each function's last DIRECTLY WRITTEN definition, which for these seven is
// still the pre-fix one (correctly still saying MUSTER, since that is
// historical record, not live behavior) -- asserting against that would be
// testing the wrong thing.
//
// So the honest, checkable guarantee here is narrower: muster_116's own DO
// block still names every function it is supposed to fix. If a future edit
// drops one from that list, this catches it; verifying the live database
// actually reads clean needs a live check (see this session's own
// pg_proc.prosrc query, not repeated here) rather than a static file test.
test("muster_116's replace-in-place block still targets every function it fixed", () => {
  const migration = readFileSync(
    join(migrationsDir, "20260926032118_muster_116_customer_facing_copy_cavscope_branding.sql"),
    "utf8",
  );
  for (const fn of [
    "generate_sitrep", "q_jurisdiction_advisory", "sitrep_jurisdiction_md",
    "sitrep_report_model", "sync_controls", "do_promote_finding", "agent_tools",
    "muster_beta_signup_guard", "muster_save_brand",
  ]) {
    assert.match(migration, new RegExp(`'${fn}'`), `muster_116 no longer names ${fn} in its fix list`);
  }
  assert.match(migration, /replace\(d, 'MUSTER', 'CavScope'\)/);
});

test("q_brand's default (non-white-label) brand says CavScope", () => {
  const body = newestBody("muster.q_brand");
  assert.match(body, /'brand_name', 'CavScope'/);
  assert.match(body, /'brand_mark', 'CS'/);
  assert.match(body, /Prepared under the CavScope Assurance Framework/);
  // The sentinel value and key name stay lowercase/unchanged -- app.html
  // compares against the literal string 'muster' and reads
  // hide_muster_attribution by name.
  assert.match(body, /'mode', 'muster'/);
  assert.match(body, /hide_muster_attribution/);
});

test("autotriage's risk_opened email says CavScope, not MUSTER", () => {
  const body = newestBody("muster.autotriage");
  assert.match(body, /format\('\[CavScope\] New %s risk on %s: %s'/);
  assert.match(body, /CavScope opened a new %s-severity risk/);
});
