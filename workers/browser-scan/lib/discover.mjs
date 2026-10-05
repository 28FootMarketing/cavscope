// Page discovery. Pure: takes text, returns URLs. The worker does the fetching.
//
// Order: sitemap.xml URLs (one level of sitemap index), else the homepage plus same-origin links.
// Always same-origin, never past the cap, never a path robots.txt disallows for us.

export const MAX_PAGES = 25;
export const AGENT_TOKEN = "cavscope";

export function normalizeUrl(href, base) {
  let u;
  try { u = new URL(href, base); } catch { return null; }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  u.hash = "";
  if (u.pathname.length > 1) u.pathname = u.pathname.replace(/\/+$/, "") || "/";
  return u.toString();
}

export function sameOrigin(a, b) {
  try { return new URL(a).origin === new URL(b).origin; } catch { return false; }
}

// <loc> values, from a urlset or a sitemapindex. `kind` says which one it was.
export function parseSitemap(xml) {
  const locs = [...String(xml).matchAll(/<loc>\s*([^<\s][^<]*?)\s*<\/loc>/gi)]
    .map((m) => m[1].replace(/&amp;/g, "&").trim());
  const kind = /<sitemapindex[\s>]/i.test(xml) ? "index" : "urlset";
  return { kind, locs };
}

// robots.txt: the group for our agent token if there is one, else the * group. Returns a matcher.
export function parseRobots(text) {
  const groups = [];
  let cur = null;
  for (const raw of String(text || "").split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, "").trim();
    if (!line) { cur = null; continue; }
    const idx = line.indexOf(":");
    if (idx < 0) continue;
    const field = line.slice(0, idx).trim().toLowerCase();
    const value = line.slice(idx + 1).trim();
    if (field === "user-agent") {
      if (!cur || cur.rules.length) { cur = { agents: [], rules: [] }; groups.push(cur); }
      cur.agents.push(value.toLowerCase());
    } else if ((field === "allow" || field === "disallow") && cur) {
      cur.rules.push({ allow: field === "allow", path: value });
    }
  }
  const pick = groups.find((g) => g.agents.includes(AGENT_TOKEN)) ?? groups.find((g) => g.agents.includes("*"));
  const rules = pick ? pick.rules.filter((r) => r.path !== "") : [];
  return {
    allowed(pathAndQuery) {
      let best = null;
      for (const r of rules) {
        const pat = r.path.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\\\$$/, "$");
        const re = new RegExp("^" + (r.path.endsWith("$") ? pat : pat));
        if (re.test(pathAndQuery) && (!best || r.path.length > best.path.length || (r.path.length === best.path.length && r.allow)))
          best = r;
      }
      return best ? best.allow : true;
    },
    ruleCount: rules.length,
  };
}

// Pick the pages to visit. `candidates` are absolute URLs in preference order (homepage first).
export function selectPages({ origin, home, candidates, robots, cap = MAX_PAGES }) {
  const seen = new Set();
  const out = [];
  const skippedByRobots = [];
  const add = (u) => {
    const n = normalizeUrl(u, home);
    if (!n || !sameOrigin(n, origin) || seen.has(n)) return;
    seen.add(n);
    const p = new URL(n);
    if (robots && !robots.allowed(p.pathname + p.search)) { skippedByRobots.push(n); return; }
    if (out.length < cap) out.push(n);
  };
  add(home);
  for (const c of candidates) add(c);
  return { pages: out, skippedByRobots };
}
