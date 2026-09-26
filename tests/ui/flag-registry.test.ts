// The feature flag registry has to tell the truth about itself.
//
//   node --experimental-strip-types --test tests/ui/flag-registry.test.ts
//
// muster.feature_flags carries an `enforcement` array per flag saying where the
// key is actually read: 'sql', 'app', 'edge', or nothing at all. The Super Admin
// console renders that column directly -- an enforced flag gets live switches, an
// unwired one gets a "read by nothing" badge and disabled switches.
//
// That only works while the column is accurate. This test reads the enforcement
// claims out of migration muster_052 and checks each one against the code, in
// both directions:
//
//   claims 'app'  -> the key must appear in app.html
//   claims 'sql'  -> some migration must pass it to has_flag / flag_state_for_org
//   claims 'edge' -> the key must appear under supabase/functions
//   claims nothing -> no migration may gate on it (an unwired flag that is in
//                     fact enforced is the more dangerous direction: the console
//                     would disable a switch that is silently live)
//
// The failure this guards against is the one the registry was built to fix. In
// September 2026 eleven of twenty-two flags were enforced nowhere, and nothing
// in the console said so, so three switches that read as safety controls --
// scheduled_scans, super_admin_console, telegram_alerts -- did nothing at all.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const migrationsDir = join(repoRoot, "supabase", "migrations");

const read = (p: string) => readFileSync(join(repoRoot, p), "utf8");

const REGISTRY_MIGRATION = "20260916022827_muster_055_flag_registry_metadata.sql";

// Every migration body concatenated, for "is this key gated anywhere in SQL".
const allMigrations = readdirSync(migrationsDir)
  .filter((f) => f.endsWith(".sql"))
  .map((f) => readFileSync(join(migrationsDir, f), "utf8"))
  .join("\n");

const edgeFunctions = (() => {
  const dir = join(repoRoot, "supabase", "functions");
  const out: string[] = [];
  const walk = (d: string) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const full = join(d, e.name);
      if (e.isDirectory()) walk(full);
      else if (e.name.endsWith(".ts")) out.push(readFileSync(full, "utf8"));
    }
  };
  walk(dir);
  return out.join("\n");
})();

// Pull (key -> enforcement[]) out of the two data blocks in muster_052. Each
// tuple in both blocks contains exactly one `array[...]`, which is the
// enforcement value, so the key is the last quoted identifier before it.
function enforcementClaims(): Map<string, string[]> {
  const sql = readFileSync(join(migrationsDir, REGISTRY_MIGRATION), "utf8");
  const blocks = [
    sql.slice(sql.indexOf("from (values"), sql.indexOf(") as v(key,")),
    sql.slice(sql.indexOf("insert into muster.feature_flags"), sql.indexOf("on conflict (key)")),
  ];
  const claims = new Map<string, string[]>();
  for (const block of blocks) {
    for (const m of block.matchAll(/array\[([^\]]*)\]/g)) {
      const before = block.slice(0, m.index);
      const keys = [...before.matchAll(/\(\s*'([a-z][a-z0-9_]{2,47})'/g)];
      assert.ok(keys.length, "every array[...] must follow a flag key");
      const key = keys[keys.length - 1][1];
      const enf = m[1]
        .split(",")
        .map((v) => v.trim().replace(/^'|'$/g, ""))
        .filter(Boolean);
      claims.set(key, enf);
    }
  }
  return claims;
}

const claims = enforcementClaims();

test("muster_052 declares enforcement for every flag it touches", () => {
  // 22 backfilled + 13 inserted. If this number moves, a flag was added or
  // removed without a matching enforcement claim, which is the drift itself.
  assert.equal(claims.size, 35);
  for (const [key, enf] of claims) {
    for (const where of enf) {
      assert.ok(["sql", "app", "edge"].includes(where), `${key}: unknown enforcement "${where}"`);
    }
  }
});

test("every flag claiming 'app' enforcement is read by app.html", () => {
  const app = read("app.html");
  for (const [key, enf] of claims) {
    if (!enf.includes("app")) continue;
    assert.ok(app.includes(key), `${key} claims app enforcement but never appears in app.html`);
  }
});

test("every flag claiming 'sql' enforcement is passed to a flag check in a migration", () => {
  for (const [key, enf] of claims) {
    if (!enf.includes("sql")) continue;
    const gated = new RegExp(`(has_flag|flag_state_for_org)\\s*\\([^)]*'${key}'`).test(allMigrations);
    assert.ok(gated, `${key} claims sql enforcement but no migration passes it to has_flag/flag_state_for_org`);
  }
});

test("every flag claiming 'edge' enforcement appears in an edge function", () => {
  for (const [key, enf] of claims) {
    if (!enf.includes("edge")) continue;
    assert.ok(edgeFunctions.includes(key), `${key} claims edge enforcement but never appears under supabase/functions`);
  }
});

test("a flag claiming no enforcement is not secretly gated in SQL", () => {
  // The dangerous direction. The console disables the switches on an unwired
  // flag; if SQL were in fact reading it, that switch would be live and the
  // console would be hiding a working control rather than exposing a dead one.
  for (const [key, enf] of claims) {
    if (enf.length) continue;
    const gated = new RegExp(`(has_flag|flag_state_for_org)\\s*\\([^)]*'${key}'`).test(allMigrations);
    assert.ok(!gated, `${key} claims no enforcement but a migration gates on it`);
  }
});

test("sitrep_ready_email was retired cleanly (muster_111 deletes what muster_110 inserted)", () => {
  // muster_110 shipped sitrep_ready gated behind a NEW feature flag override,
  // which turned out to be unreachable by an ordinary tenant --
  // feature_flag_overrides is writable only from the super-admin console, so
  // "enable per org" was a switch nobody but a super admin could flip.
  // muster_111 replaced it with a plain organizations column
  // (sitrep_ready_alerts_enabled, mirroring critical_alerts_enabled) that an
  // executive can flip themselves via muster_set_sitrep_alert_preference. The
  // flag row and any override for it must both be gone, not just unused --
  // a registry row nothing reads any more is exactly the "reports a control
  // that does not exist" problem muster_052 itself was written to prevent.
  const migration = readFileSync(
    join(migrationsDir, "20260926020703_muster_111_sitrep_ready_org_preference_and_ui_rpcs.sql"),
    "utf8",
  );
  assert.match(migration, /delete from muster\.feature_flags where key = 'sitrep_ready_email'/);
  assert.match(migration, /delete from muster\.feature_flag_overrides where flag_key = 'sitrep_ready_email'/);
  // The LATEST muster_engine_sitrep (this migration's own CREATE OR REPLACE,
  // which is what actually runs -- migrations are append-only, so an earlier
  // file's body, muster_110's, still literally contains the old
  // flag_state_for_org('sitrep_ready_email') call and always will) must read
  // the new column instead, not the retired flag.
  const latestBody = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION public.muster_engine_sitrep"));
  assert.doesNotMatch(latestBody, /'sitrep_ready_email'/, "the current muster_engine_sitrep still reads the retired flag");
  assert.match(latestBody, /v_org_row\.sitrep_ready_alerts_enabled/, "the current muster_engine_sitrep must gate on the new column");
});

test("the four flags muster_053 wired are gated where it says they are", () => {
  const wiring = readFileSync(join(migrationsDir, "20260916022923_muster_056_wire_the_dead_feature_flags.sql"), "utf8");
  // scheduled_scans gates the due-scan CTE only -- not the manual/api catch-up
  // claim below it, which is a member's own request and a different flag.
  assert.match(wiring, /and muster\.flag_state_for_org\(w\.organization_id, 'scheduled_scans'\)/);
  assert.match(wiring, /and muster\.flag_state_for_org\(organization_id, 'email_alerts'\)/);
  assert.match(wiring, /if not muster\.flag_state_for_org\(null, 'support_impersonation'\)/);
  assert.match(wiring, /if not muster\.flag_state_for_org\(null, 'admin_url_scanner'\)/);

  // Held, not discarded: an alert blocked by email_alerts stays pending and
  // drains when the flag comes back on.
  assert.doesNotMatch(wiring, /'email_alerts'[\s\S]{0,400}status = 'skipped'/);
});

test("flag_state_for_org ignores per-user overrides, unlike has_flag", () => {
  const wiring = readFileSync(join(migrationsDir, "20260916022923_muster_056_wire_the_dead_feature_flags.sql"), "utf8");
  const body = wiring.slice(
    wiring.indexOf("create or replace function muster.flag_state_for_org"),
    wiring.indexOf("comment on function muster.flag_state_for_org"),
  );
  assert.ok(body.includes("and user_id is null"), "the org override lookup must exclude user-scoped rows");
  assert.ok(!body.includes("current_user_id"), "flag_state_for_org must not consult the calling user");
});

test("the console disables the switches on a flag nothing reads", () => {
  // The registry editor lives in admin.html, the only super admin console.
  const admin = read("admin.html");
  const start = admin.indexOf("function flagRegistry(reg)");
  const end = admin.indexOf("// Surfaces the design calls for", start);
  assert.ok(start > 0 && end > start, "flagRegistry() not found in admin.html");
  const panel = admin.slice(start, end);
  assert.ok(panel.includes("read by nothing"), "an unwired flag must be labelled in words");
  // Both switches carry the wired-conditional disabled attribute.
  assert.equal((panel.match(/\$\{wired \? '' : 'disabled'\}/g) || []).length, 2);
  // And deletion is only offered for a flag nothing reads.
  assert.match(panel, /\$\{wired \? '' : `<div[^`]*data-act="flag-delete"/);
});

test("the console resolves per-org state without the viewing admin's own overrides", () => {
  // orgs_enabled comes from flag_state_for_org, so the number on screen does
  // not change depending on which super admin is looking at it.
  const rpcs = readFileSync(join(migrationsDir, "20260916023009_muster_057_flag_registry_rpcs.sql"), "utf8");
  assert.match(rpcs, /'orgs_enabled',[\s\S]{0,120}muster\.flag_state_for_org\(o\.id, f\.key\)/);
  assert.doesNotMatch(rpcs.slice(rpcs.indexOf("muster_admin_flag_registry"), rpcs.indexOf("muster_admin_create_flag")), /has_flag/);
});

test("a flag that code reads cannot be deleted from the console", () => {
  const rpcs = readFileSync(join(migrationsDir, "20260916023009_muster_057_flag_registry_rpcs.sql"), "utf8");
  const del = rpcs.slice(rpcs.indexOf("function public.muster_admin_delete_flag"));
  assert.match(del, /array_length\(f\.enforcement, 1\), 0\) > 0/);
  assert.match(del, /raise exception 'flag % is enforced in %/);
});

test("every new admin RPC is revoked from anon", () => {
  // Supabase grants EXECUTE on every new public function to anon and
  // authenticated by default, and `revoke ... from public` does not undo it.
  const rpcs = readFileSync(join(migrationsDir, "20260916023009_muster_057_flag_registry_rpcs.sql"), "utf8");
  for (const fn of [
    "muster_admin_flag_registry",
    "muster_admin_create_flag",
    "muster_admin_clear_flag_override",
    "muster_admin_set_flag_plan_minimum",
    "muster_admin_delete_flag",
  ]) {
    assert.ok(
      new RegExp(`revoke all on function public\\.${fn}\\(`).test(rpcs),
      `${fn} is never revoked from anon`,
    );
    assert.ok(new RegExp(`function public\\.${fn}\\([^)]*\\) to authenticated, service_role`).test(rpcs), `${fn} is never granted`);
  }
});

test("the workspace reads white_label_enabled, which is the key that exists", () => {
  const app = read("app.html");
  assert.match(app, /o\.flags && o\.flags\.white_label_enabled/);
  // `white_label` on its own was read here until 2026-09-16 and is not a flag,
  // so the badge said OFF no matter what the real flag was set to.
  assert.doesNotMatch(app, /o\.flags\.white_label\b(?!_enabled)/);
});

test("every nav item in navFlagMap exists, and every flag it names is real", () => {
  const app = read("app.html");
  const map = app.slice(app.indexOf("navFlagMap: {"), app.indexOf("applyFlagsToNav(flags)"));
  const pairs = [...map.matchAll(/^\s{8}([a-zA-Z]+):\s*'([a-z_]+)',$/gm)];
  assert.equal(pairs.length, 10);
  for (const [, view, key] of pairs) {
    assert.ok(app.includes(`data-view="${view}"`), `navFlagMap names view ${view}, which has no nav button`);
    assert.ok(claims.has(key), `navFlagMap names flag ${key}, which muster_052 never declares`);
    assert.ok(claims.get(key)!.includes("app"), `${key} gates a nav item but does not claim app enforcement`);
  }
});

test("nav gating fails open when a flag is missing from the payload", () => {
  // A partial workspace load must not silently strip half a tenant's sidebar.
  const app = read("app.html");
  assert.match(app, /const on = !\(key in flags\) \|\| !!flags\[key\];/);
});
