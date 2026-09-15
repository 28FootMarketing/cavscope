/**
 * Mechanical adapter: turns the deployed scan engine into an importable module.
 *
 * WHY THIS IS AN ADAPTER AND NOT A COPY
 *
 * `supabase/functions/muster-scan/index.ts` is the only place the 38 rules live.
 * A second copy of that logic would drift the first time a rule changed, and a
 * local runner that scores a site differently from the product is worse than no
 * local runner at all -- it produces a number we would then have to defend.
 *
 * So this reads the real engine source at runtime and removes exactly four
 * things: the Deno runtime typings import, the Supabase client, the two ingest
 * RPCs at the tail of runScan(), and the Deno.serve() handler. Every rule, every
 * threshold, every evidence key and the UA string come through untouched.
 *
 * Every transform asserts it matched, and the excised tail is checked for `add({`
 * before it is dropped. If someone restructures the engine, this fails loudly
 * instead of quietly scanning with different rules.
 */

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";

const HERE = dirname(fileURLToPath(import.meta.url));
export const ENGINE_DIR = join(HERE, "..", "..", "supabase", "functions", "muster-scan");
export const ENGINE_SRC = join(ENGINE_DIR, "index.ts");

const RUNTIME_TYPES = 'import "jsr:@supabase/functions-js/edge-runtime.d.ts";\n';
const CLIENT_IMPORT = 'import { createClient } from "jsr:@supabase/supabase-js@2";\n';
const EMAIL_IMPORT = '"./email-auth.ts"';
const DB_CONST = 'const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);\n';
const TAIL_ANCHOR = "  const { data: ingest, error: ingestErr } = await db.rpc(\"muster_engine_ingest\"";

/**
 * The replacement tail. The edge function hands `evidence` and `findings` to
 * Postgres, which assigns ids, fingerprints and the posture score. Locally we
 * return them as-is -- scoring happens in score.mjs, from the same weights the
 * database uses.
 */
const LOCAL_TAIL = `  return { scan_id: job.scan_id, website: job.website_name, final_url: finalUrl, scan: scanMeta, evidence, findings };
}

export { runScan, ENGINE_VERSION };
`;

function cut(src, needle, what) {
  const n = src.split(needle).length - 1;
  if (n !== 1) throw new Error(`adapter: expected exactly 1 occurrence of ${what}, found ${n}. The engine was restructured; update tools/local-scan/adapt.mjs.`);
  return src.replace(needle, "");
}

/** Reads the engine source and returns the adapted module text. */
export async function adaptSource() {
  let src = await readFile(ENGINE_SRC, "utf8");

  src = cut(src, RUNTIME_TYPES, "the Deno runtime typings import");
  src = cut(src, CLIENT_IMPORT, "the supabase-js import");
  src = cut(src, DB_CONST, "the service-role client");

  if (src.split(EMAIL_IMPORT).length - 1 !== 1) throw new Error("adapter: expected exactly 1 relative import of email-auth.ts");
  src = src.replace(EMAIL_IMPORT, JSON.stringify(pathToFileURL(join(ENGINE_DIR, "email-auth.ts")).href));

  const at = src.indexOf(TAIL_ANCHOR);
  if (at === -1) throw new Error("adapter: could not find the muster_engine_ingest call that ends runScan(). Update tools/local-scan/adapt.mjs.");

  const dropped = src.slice(at);
  // The excised region must be exactly the two RPCs, the return, and Deno.serve.
  for (const required of ["muster_engine_sitrep", "Deno.serve("]) {
    if (!dropped.includes(required)) throw new Error(`adapter: the region after the ingest call does not contain ${required}; refusing to cut a region I do not recognise.`);
  }
  if (dropped.includes("add({")) throw new Error("adapter: the region after the ingest call raises a finding. Cutting it would silently drop a rule. Update tools/local-scan/adapt.mjs.");

  return src.slice(0, at) + LOCAL_TAIL;
}

/** Writes the adapted engine to a temp dir and returns its file URL. */
export async function loadEngine() {
  const out = join(tmpdir(), "muster-local-scan");
  await mkdir(out, { recursive: true });
  const file = join(out, "engine.adapted.ts");
  await writeFile(file, await adaptSource(), "utf8");
  return pathToFileURL(file).href;
}
