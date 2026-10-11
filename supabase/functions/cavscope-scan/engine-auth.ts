// The engine's request gate: the caller must present the shared secret that
// Postgres holds in Vault (cavscope_engine_secret()).
//
// Why this is its own module: the gate used to read `const { data: secret } = ...`
// and treat a missing value as "unauthorized". A failed read of the secret (the
// API gateway refused one of twenty simultaneous calls with a 401 on 2026-10-11,
// scan 309) therefore answered a perfectly valid caller with the same 401 a wrong
// secret gets, and nothing recorded that the read had failed. A read that fails is
// not a wrong secret. It is retried once, and if it still fails the answer is 503
// with the reason, so the caller (and the 2-minute sweep that claims queued scans)
// knows the engine could not check, not that the caller was refused.

export type SecretRead = { data: string | null; error: { message: string } | null };
export type AuthVerdict =
  | { ok: true }
  | { ok: false; status: 401; body: { error: "unauthorized" } }
  | { ok: false; status: 503; body: { error: "secret_unavailable"; detail: string } };

export async function checkEngineAuth(
  read: () => Promise<SecretRead>,
  provided: string,
): Promise<AuthVerdict> {
  let r = await read();
  if (r.error || !r.data) r = await read();
  if (r.error) return { ok: false, status: 503, body: { error: "secret_unavailable", detail: String(r.error.message).slice(0, 300) } };
  // No error and no value means the secret is not configured: fail closed, as a refusal.
  if (!r.data || provided !== r.data) return { ok: false, status: 401, body: { error: "unauthorized" } };
  return { ok: true };
}
