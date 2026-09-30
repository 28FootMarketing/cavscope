// tools/live-sweep/sweep.mjs -- renders every workspace view in demo mode, as a
// live tenant fed tools/live-sweep/fixture.local.json, and in demo again, then
// prints each view's lines that are identical in demo and live. See README.md.
import { createRequire } from 'module';
import { readFileSync, writeFileSync } from 'fs';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PW_PATH || 'playwright');
const fx = JSON.parse(readFileSync(new URL('./fixture.local.json', import.meta.url)));
const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
const errors = []; page.on('pageerror', e => errors.push(String(e)));
page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
await page.route(/supabase\.(co|in)|jsdelivr|unpkg|cdnjs|googleapis|gstatic/, r => r.abort());
await page.goto('file://' + (process.env.APP || new URL('../../app.html', import.meta.url).pathname));
await page.waitForTimeout(700);
const views = await page.evaluate(() => [...document.querySelectorAll('section.view')].map(s => s.id));
const dump = () => page.evaluate(async (views) => {
  const out = {};
  for (const v of views) { showView(v); await new Promise(r => setTimeout(r, 30)); out[v] = document.getElementById(v).innerText; }
  return out;
}, views);
const demo = await dump();
await page.evaluate((fx) => {
  const rulesAsked = ids => ids.map(id => ({ rule_id: id, active: fx.rules[id] ?? false, title: id, default_severity: 'low' }));
  const handlers = {
    cavscope_claim_invites: () => null,
    cavscope_onboarding_status: () => ({ next: 'workspace', organizations: [{ id: 3 }] }),
    cavscope_my_workspace: () => ({ user: { id: 2, name: 'Owner' }, preferences: null, is_super_admin: false, platform_flags: {}, organizations: [Object.assign({}, fx.org, { role: 'executive' })] }),
    cavscope_website_overview: () => JSON.parse(JSON.stringify(fx.overview)),
    cavscope_latest_sitrep: () => JSON.parse(JSON.stringify(fx.sitrep)),
    cavscope_risks: () => fx.risks,
    cavscope_risk_appetite: () => fx.appetite,
    cavscope_pending_invites: () => [],
    cavscope_rule_status: (a) => rulesAsked(a.p_rule_ids || []),
  };
  window.__rpcCalls = [];
  Live.sb = { rpc: async (fn, args) => { window.__rpcCalls.push(fn); const h = handlers[fn]; return h ? { data: h(args || {}), error: null } : { data: null, error: { message: 'unstubbed ' + fn } }; },
              auth: { signOut: async () => ({}), getSession: async () => ({ data: { session: null } }) } };
  Live.session = { user: { email: 'owner@example.com', app_metadata: {} } };
}, fx);
await page.evaluate(() => Live.enter());
await page.waitForTimeout(500);
const live = await dump();
await page.evaluate(() => Live.showDemo()); await page.waitForTimeout(300);
const back = await dump();
const notRestored = views.filter(v => demo[v] !== back[v]);
const calls = await page.evaluate(() => window.__rpcCalls);
const report = {};
for (const v of views) {
  const d = new Set(demo[v].split('\n').map(s => s.trim()).filter(Boolean));
  report[v] = live[v].split('\n').map(s => s.trim()).filter(Boolean).filter(l => d.has(l));
}
writeFileSync(new URL('./sweep-out.local.json', import.meta.url), JSON.stringify({ errors, calls, notRestored, report, live, demo, back }, null, 1));
console.log(JSON.stringify({ errors: errors.filter(e => !/ERR_(FAILED|FILE_NOT_FOUND)/.test(e)), calls: [...new Set(calls)], notRestored }, null, 1));
for (const v of views) console.log(`\n=== ${v}: ${report[v].length} lines identical to demo`);
await browser.close();
