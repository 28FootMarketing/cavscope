import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { checkEngineAuth, type SecretRead } from "../../supabase/functions/cavscope-scan/engine-auth.ts";

const root = join(import.meta.dirname, "../..");
const seq = (...reads: SecretRead[]) => { let i = 0; return { read: async () => reads[Math.min(i++, reads.length - 1)], calls: () => i }; };

test("the right secret passes, a wrong or empty one is 401", async () => {
  assert.deepEqual(await checkEngineAuth(seq({ data: "s3", error: null }).read, "s3"), { ok: true });
  assert.equal((await checkEngineAuth(seq({ data: "s3", error: null }).read, "nope") as any).status, 401);
  assert.equal((await checkEngineAuth(seq({ data: "s3", error: null }).read, "") as any).status, 401);
});

test("an unconfigured secret fails closed as 401, and an empty header never matches an empty secret", async () => {
  const v = await checkEngineAuth(seq({ data: null, error: null }).read, "") as any;
  assert.equal(v.ok, false);
  assert.equal(v.status, 401);
  const w = await checkEngineAuth(seq({ data: "", error: null }).read, "") as any;
  assert.equal(w.status, 401);
});

test("a failed read is retried once and a valid caller then passes (the scan 309 case)", async () => {
  const s = seq({ data: null, error: { message: "401 from gateway" } }, { data: "s3", error: null });
  assert.deepEqual(await checkEngineAuth(s.read, "s3"), { ok: true });
  assert.equal(s.calls(), 2);
});

test("a read that keeps failing is 503 with the reason, never the 401 a wrong secret gets", async () => {
  const s = seq({ data: null, error: { message: "gateway refused" } });
  const v = await checkEngineAuth(s.read, "s3") as any;
  assert.equal(v.status, 503);
  assert.equal(v.body.error, "secret_unavailable");
  assert.match(v.body.detail, /gateway refused/);
  assert.equal(s.calls(), 2);
});

test("a wrong secret is not retried into a pass, and the retry never reads a second time when the first read worked", async () => {
  const s = seq({ data: "s3", error: null });
  await checkEngineAuth(s.read, "bad");
  assert.equal(s.calls(), 1);
});

test("the handler uses the gate and no longer discards the read error", () => {
  const src = readFileSync(join(root, "supabase/functions/cavscope-scan/index.ts"), "utf8");
  assert.match(src, /checkEngineAuth\(/);
  assert.doesNotMatch(src, /const \{ data: secret \} = await db\.rpc\("cavscope_engine_secret"\)/);
});
