// WCAG contrast math for A11Y-009. Pure: no browser.
//   node --experimental-strip-types --test tests/browser/contrast.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
// @ts-ignore: plain ES module
import * as c from "../../workers/browser-scan/lib/contrast.mjs";

const R = (a: string, b: string) => Math.round(c.contrastRatio(c.parseColor(a), c.parseColor(b)) * 100) / 100;

test("the standard WCAG relative-luminance formula gives the known reference ratios", () => {
  assert.equal(R("#000", "#fff"), 21);
  assert.equal(R("#fff", "#fff"), 1);
  assert.equal(R("#777", "#fff"), 4.48);      // the classic just-fails-AA grey
  assert.equal(R("#767676", "#fff"), 4.54);   // the lightest grey that passes AA on white
});

test("the input border from the fixture site is 4.1:1 on white and clears the 3:1 UI rule", () => {
  assert.equal(R("#6B7F99", "#ffffff"), 4.1);
  assert.ok(R("#6B7F99", "#fff") >= c.UI_RATIO);
  assert.ok(R("#6B7F99", "#fff") < c.TEXT_RATIO, "and would fail as body text, which is why the threshold depends on what it is");
});

test("colour parsing: hex short and long, rgb comma and space syntax, alpha, transparent, junk", () => {
  assert.deepEqual(c.parseColor("#f00"), { r: 255, g: 0, b: 0, a: 1 });
  assert.deepEqual(c.parseColor("#F4B223"), { r: 244, g: 178, b: 35, a: 1 });
  assert.deepEqual(c.parseColor("rgb(10, 20, 30)"), { r: 10, g: 20, b: 30, a: 1 });
  assert.deepEqual(c.parseColor("rgb(10 20 30 / 50%)"), { r: 10, g: 20, b: 30, a: 0.5 });
  assert.equal(c.parseColor("rgba(0, 0, 0, 0)").a, 0);
  assert.equal(c.parseColor("transparent").a, 0);
  assert.equal(c.parseColor("var(--navy)"), null, "an unresolved custom property is not a colour");
  assert.equal(c.parseColor("currentColor"), null);
  assert.equal(c.parseColor("#12"), null);
});

test("large text is 24px, or 18.66px and bold; the threshold follows", () => {
  assert.equal(c.requiredRatio({ fontSizePx: 16, fontWeight: 400 }), 4.5);
  assert.equal(c.requiredRatio({ fontSizePx: 24, fontWeight: 400 }), 3);
  assert.equal(c.requiredRatio({ fontSizePx: 18.66, fontWeight: 700 }), 3);
  assert.equal(c.requiredRatio({ fontSizePx: 18.66, fontWeight: 400 }), 4.5);
  assert.equal(c.requiredRatio({ fontSizePx: 18, fontWeight: 700 }), 4.5, "18px bold is under 18.66");
  assert.equal(c.requiredRatio({ kind: "ui" }), 3);
  assert.equal(c.isLargeText(19, "bold"), true);
});

test("a gradient is read as plain colour stops, and refused when it is not", () => {
  const stops = c.gradientStops("linear-gradient(to right, rgb(1, 2, 3), rgba(4, 5, 6, 0.5) 40%, #fff)");
  assert.equal(stops.length, 3);
  assert.equal(stops[1].a, 0.5);
  assert.equal(c.gradientStops("none"), null);
  assert.equal(c.gradientStops('url("hero.jpg")'), null);
  assert.equal(c.gradientStops("linear-gradient(red, blue)"), null, "named colours are not guessed at");
  assert.equal(c.gradientStops("linear-gradient(rgba(0,0,0,.5), url(x.png))"), null, "a gradient over an image is not a solid backdrop");
});

test("gold text on a navy gradient resolves to a pass from the worst stop, with the ratio stated", () => {
  const r = c.resolveTextContrast({
    color: "rgb(244, 178, 35)", fontSizePx: 16, fontWeight: "400",
    backgrounds: [{ kind: "gradient", value: "linear-gradient(135deg, rgb(10, 31, 68) 0%, rgb(26, 58, 110) 100%)" }],
  });
  assert.equal(r.status, "pass");
  assert.ok(r.ratio >= 5.5, `weakest stop is ${r.ratio}`);
  assert.match(r.reason, /weakest point across the gradient stops/);
});

test("the WEAKEST gradient stop decides: a gradient that runs into a light colour fails", () => {
  const r = c.resolveTextContrast({
    color: "rgb(244, 178, 35)", fontSizePx: 16, fontWeight: "400",
    backgrounds: [{ kind: "gradient", value: "linear-gradient(90deg, rgb(10, 31, 68), rgb(250, 240, 200))" }],
  });
  assert.equal(r.status, "fail");
  assert.ok(r.ratio < 4.5);
});

test("a translucent colour layer is composited over what is behind it before measuring", () => {
  // White at 50% over black is mid grey: grey text on it is nearly invisible.
  const r = c.resolveTextContrast({
    color: "rgb(128, 128, 128)", fontSizePx: 16, fontWeight: "400",
    backgrounds: [{ kind: "color", value: "rgba(255, 255, 255, 0.5)" }, { kind: "color", value: "rgb(0, 0, 0)" }],
  });
  assert.equal(r.status, "fail");
});

test("anything that cannot be read as plain colours is UNRESOLVED, never a pass", () => {
  const base = { color: "rgb(0, 0, 0)", fontSizePx: 16, fontWeight: "400" };
  assert.equal(c.resolveTextContrast({ ...base, backgrounds: [{ kind: "image", value: 'url("x.jpg")' }] }).status, "unresolved");
  assert.equal(c.resolveTextContrast({ ...base, backgrounds: [] }).status, "unresolved");
  assert.equal(c.resolveTextContrast({ ...base, backgrounds: [{ kind: "gradient", value: 'url("x.jpg")' }] }).status, "unresolved");
  assert.equal(c.resolveTextContrast({ ...base, color: "var(--x)", backgrounds: [{ kind: "color", value: "#fff" }] }).status, "unresolved");
});

test("large text uses the 3:1 threshold in the verdict", () => {
  const bg = [{ kind: "color", value: "#ffffff" }];
  const grey = "rgb(130, 130, 130)"; // about 3.5:1 on white
  assert.equal(c.resolveTextContrast({ color: grey, backgrounds: bg, fontSizePx: 16, fontWeight: "400" }).status, "fail");
  assert.equal(c.resolveTextContrast({ color: grey, backgrounds: bg, fontSizePx: 28, fontWeight: "400" }).status, "pass");
});
