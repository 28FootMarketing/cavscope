// The final text of a SITREP function, for tests that read SQL source.
//
// Migrations are append-only and some functions are changed by an in-place edit
// rather than a new full definition (cavscope.generate_sitrep has been edited that
// way since the browser engine). Such a migration lists its whole change as pairs:
//     patch_once(d, $o$ OLD $o$, $n$ NEW $n$)        (20261011032759 and later)
//     pg_temp.sub(d, $q$ OLD $q$, $q$ NEW $q$)       (the browser foundation, 20261005020553) This returns the newest full definition with every later migration's pairs
// applied, so a test sees what is live and a stale definition cannot hide a change.

import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "supabase", "migrations");
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();

/** @param name unqualified function name, e.g. "generate_sitrep" */
export function finalFunctionSql(name: string): string {
  const header = new RegExp(`create or replace function (muster|cavscope)\\.${name}\\b`, "i");
  const defining = files.filter((f) => header.test(readFileSync(join(dir, f), "utf8")));
  if (!defining.length) throw new Error(`no migration defines ${name}`);
  const last = defining[defining.length - 1];
  const sql = readFileSync(join(dir, last), "utf8");
  const at = sql.search(header);
  const tag = /\bas\s+(\$[a-z]*\$)/i.exec(sql.slice(at));
  if (!tag) throw new Error(`no body quote found for ${name}`);
  const open = at + tag.index;
  const close = sql.indexOf(`${tag[1]};`, open + tag[0].length);
  let text = sql.slice(at, close);
  for (const f of files.filter((x) => x > last)) {
    const body = readFileSync(join(dir, f), "utf8");
    const pairs = [
      ...body.matchAll(/\$o\$([\s\S]*?)\$o\$\s*,\s*\$n\$([\s\S]*?)\$n\$/g),
      ...body.matchAll(/pg_temp\.sub\(d,\s*\$q\$([\s\S]*?)\$q\$,\s*\$q\$([\s\S]*?)\$q\$\)/g),
    ];
    for (const m of pairs) {
      if (text.split(m[1]).length === 2) text = text.replace(m[1], () => m[2]);
    }
  }
  return text;
}
