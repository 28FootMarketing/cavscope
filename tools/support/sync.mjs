// node tools/support/sync.mjs -- writes tools/support/widget.html into each page between
// <!-- support:start --> and <!-- support:end -->. Same arrangement as tools/tokens/sync.mjs:
// pages stay self-contained (no extra request, no shared file to fail), and
// tests/support/widget.test.ts fails if a copy drifts from this source.
import { readFileSync, writeFileSync } from 'node:fs';
export const PAGES = ['app.html', 'admin.html'];
export const START = '<!-- support:start -->';
export const END = '<!-- support:end -->';
const root = new URL('../../', import.meta.url);
export const source = () => readFileSync(new URL('./widget.html', import.meta.url), 'utf8').trimEnd();
export const block = () => `${START}\n${source()}\n${END}`;
if (process.argv[1] && process.argv[1].endsWith('sync.mjs')) {
  for (const p of PAGES) {
    const f = new URL(p, root);
    let t = readFileSync(f, 'utf8');
    const re = new RegExp(`${START}[\\s\\S]*?${END}`);
    if (re.test(t)) t = t.replace(re, () => block());
    else t = t.replace(/\n<\/body>/, () => `\n${block()}\n</body>`);
    writeFileSync(f, t);
    console.log('synced', p);
  }
}
