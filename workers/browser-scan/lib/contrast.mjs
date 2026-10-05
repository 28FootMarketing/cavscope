// WCAG contrast math. Pure: no DOM, no browser. The worker feeds it computed colour strings that the
// browser already resolved (var() and currentColor are gone in computed style), so there is nothing
// to guess here and nothing that needs a page to test.
//
// Thresholds (WCAG 2.2): 1.4.3 text 4.5:1, large text 3:1 (>= 24px, or >= 18.66px and bold);
// 1.4.11 UI component boundaries and focus indicators 3:1.

export const TEXT_RATIO = 4.5;
export const LARGE_TEXT_RATIO = 3;
export const UI_RATIO = 3;

const clamp255 = (n) => Math.min(255, Math.max(0, n));

// Accepts #rgb, #rgba, #rrggbb, #rrggbbaa, rgb()/rgba() in both comma and space syntax, and the
// keyword transparent. Returns {r,g,b,a} with r/g/b 0-255 and a 0-1, or null if it is not a plain colour.
export function parseColor(input) {
  if (typeof input !== "string") return null;
  const s = input.trim().toLowerCase();
  if (s === "transparent") return { r: 0, g: 0, b: 0, a: 0 };
  let m = /^#([0-9a-f]{3,8})$/.exec(s);
  if (m) {
    let h = m[1];
    if (h.length === 3 || h.length === 4) h = [...h].map((c) => c + c).join("");
    if (h.length !== 6 && h.length !== 8) return null;
    const n = (i) => parseInt(h.slice(i, i + 2), 16);
    return { r: n(0), g: n(2), b: n(4), a: h.length === 8 ? n(6) / 255 : 1 };
  }
  m = /^rgba?\(\s*([^)]+)\)$/.exec(s);
  if (m) {
    const parts = m[1].split(/[\s,/]+/).filter(Boolean);
    if (parts.length < 3) return null;
    const ch = (p) => (p.endsWith("%") ? (parseFloat(p) / 100) * 255 : parseFloat(p));
    const r = ch(parts[0]), g = ch(parts[1]), b = ch(parts[2]);
    let a = 1;
    if (parts[3] !== undefined) a = parts[3].endsWith("%") ? parseFloat(parts[3]) / 100 : parseFloat(parts[3]);
    if ([r, g, b, a].some((x) => Number.isNaN(x))) return null;
    return { r: clamp255(r), g: clamp255(g), b: clamp255(b), a: Math.min(1, Math.max(0, a)) };
  }
  return null;
}

// Alpha-composite fg over an opaque bg.
export function composite(fg, bg) {
  const a = fg.a ?? 1;
  return {
    r: fg.r * a + bg.r * (1 - a),
    g: fg.g * a + bg.g * (1 - a),
    b: fg.b * a + bg.b * (1 - a),
    a: 1,
  };
}

// WCAG 2.x relative luminance.
export function luminance({ r, g, b }) {
  const lin = (v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

export function contrastRatio(a, b) {
  const la = luminance(a), lb = luminance(b);
  const hi = Math.max(la, lb), lo = Math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

// Large text per WCAG: at least 24 CSS px, or at least 18.66 px (14 pt) when bold (weight >= 700).
export function isLargeText(fontSizePx, fontWeight) {
  const w = Number(fontWeight);
  const bold = Number.isFinite(w) ? w >= 700 : /bold/i.test(String(fontWeight));
  return fontSizePx >= 24 || (bold && fontSizePx >= 18.66);
}

export function requiredRatio({ kind = "text", fontSizePx = 16, fontWeight = 400 } = {}) {
  if (kind === "ui") return UI_RATIO;
  return isLargeText(fontSizePx, fontWeight) ? LARGE_TEXT_RATIO : TEXT_RATIO;
}

// Colour stops of a computed background-image. Computed style resolves custom properties, so a
// gradient built from var(--navy) arrives as plain rgb() stops. Returns null if the value is not a
// gradient made only of plain colours (an url() image, a conic gradient with unusual syntax, ...),
// because a ratio computed over part of a background would be a guess.
export function gradientStops(backgroundImage) {
  if (typeof backgroundImage !== "string" || backgroundImage === "none") return null;
  if (/url\(/i.test(backgroundImage)) return null;
  const grads = [];
  const re = /(?:repeating-)?(?:linear|radial|conic)-gradient\(/gi;
  let m;
  while ((m = re.exec(backgroundImage))) {
    let depth = 1, i = re.lastIndex;
    while (i < backgroundImage.length && depth > 0) {
      if (backgroundImage[i] === "(") depth++;
      else if (backgroundImage[i] === ")") depth--;
      i++;
    }
    if (depth !== 0) return null;
    grads.push(backgroundImage.slice(re.lastIndex, i - 1));
    re.lastIndex = i;
  }
  if (grads.length === 0) return null;
  const stops = [];
  for (const body of grads) {
    // Split on top-level commas only: rgb(1, 2, 3) contains commas.
    const parts = [];
    let depth = 0, cur = "";
    for (const ch of body) {
      if (ch === "(") depth++;
      if (ch === ")") depth--;
      if (ch === "," && depth === 0) { parts.push(cur); cur = ""; } else cur += ch;
    }
    parts.push(cur);
    for (const part of parts) {
      const cm = /(rgba?\([^)]*\)|#[0-9a-fA-F]{3,8}\b|\btransparent\b)/.exec(part);
      if (!cm) continue; // direction ("to right", "90deg", "circle at ..."), not a stop
      const c = parseColor(cm[1]);
      if (!c) return null;
      stops.push(c);
    }
  }
  return stops.length >= 2 ? stops : null;
}

// Decide a text contrast case. `layers` are the opaque-or-translucent background colours from the
// element outward (first = nearest), already reduced to plain colours or gradient stop lists by the
// worker. Returns { status: 'pass' | 'fail' | 'unresolved', ratio, required, reason }.
// 'unresolved' is never a pass: the report lists it for a person.
export function resolveTextContrast({ color, backgrounds, fontSizePx, fontWeight, kind = "text" }) {
  const fg = parseColor(color);
  const required = requiredRatio({ kind, fontSizePx, fontWeight });
  if (!fg) return { status: "unresolved", ratio: null, required, reason: "foreground colour is not a plain colour" };
  if (!Array.isArray(backgrounds) || backgrounds.length === 0)
    return { status: "unresolved", ratio: null, required, reason: "no background found" };

  // Build the set of candidate backdrops: start from white (the canvas), then paint layers from the
  // outermost to the nearest. A gradient layer multiplies the candidates by its stops.
  let candidates = [{ r: 255, g: 255, b: 255, a: 1 }];
  for (const layer of [...backgrounds].reverse()) {
    if (layer.kind === "color") {
      const c = parseColor(layer.value);
      if (!c) return { status: "unresolved", ratio: null, required, reason: "background colour is not a plain colour" };
      candidates = candidates.map((base) => composite(c, base));
    } else if (layer.kind === "gradient") {
      const stops = gradientStops(layer.value);
      if (!stops) return { status: "unresolved", ratio: null, required, reason: "background gradient could not be read as colour stops" };
      candidates = candidates.flatMap((base) => stops.map((s) => composite(s, base)));
    } else {
      return { status: "unresolved", ratio: null, required, reason: "background is an image" };
    }
  }
  // The text itself may be translucent: composite over each candidate before measuring.
  const ratios = candidates.map((bg) => contrastRatio(composite(fg, bg), bg));
  const worst = Math.min(...ratios);
  return {
    status: worst >= required ? "pass" : "fail",
    ratio: Math.round(worst * 100) / 100,
    required,
    reason: candidates.length > 1 ? "weakest point across the gradient stops" : "solid background",
  };
}
