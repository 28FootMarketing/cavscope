// publish-due
// Cron-invoked (*/15) by audio_hub_publish_due. Publishes scheduled pipeline
// rows whose time has passed via the SECURITY DEFINER seam
// audio_hub_publish_pipeline(). Idempotent: the seam only acts on
// status='scheduled'.
//
// ---------------------------------------------------------------------------
// 2026-09-07: this function had never once worked.
//
// It read SB_URL / SB_SERVICE_ROLE_KEY, which are not set on this project. The
// `!` non-null assertions on those reads are TypeScript only and compile away,
// so createClient(undefined, undefined) ran at MODULE scope and threw
// "supabaseUrl is required" before Deno.serve ever registered a handler. Every
// invocation therefore returned 500 -- ~96/day since 2026-08-04, roughly 3,200
// failures, with audio_hub_jobs empty the whole time because a job row is
// written on every publish and none was ever written.
//
// Nothing was lost: audio_hub_pipeline has no rows, so there was never anything
// due to publish. That is luck, not safety -- the first scheduled episode would
// have silently failed too.
//
// Three changes:
//   1. Fall back to SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY, which the edge
//      runtime always injects. SB_* are kept as optional overrides so setting
//      them later still works.
//   2. Config is validated inside the handler, not at module scope. A missing
//      value now returns a JSON body naming the variable instead of an opaque
//      event-loop error that is indistinguishable from a code crash.
//   3. Authorization added. verify_jwt is false on this function and it had no
//      check of its own, so anyone who could reach the URL could publish
//      content and fire Telegram messages. That was only ever "safe" because
//      the function was broken; repairing it without this would have turned a
//      dead endpoint into an open one.
// ---------------------------------------------------------------------------
//
// Secrets: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (runtime-provided),
//          SB_URL / SB_SERVICE_ROLE_KEY (optional overrides),
//          TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID (optional publish ping)

import { createClient } from 'jsr:@supabase/supabase-js@2';

const SB_URL = Deno.env.get('SB_URL') ?? Deno.env.get('SUPABASE_URL') ?? '';
const SB_KEY = Deno.env.get('SB_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const TG_TOKEN = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const TG_CHAT = Deno.env.get('TELEGRAM_CHAT_ID') ?? '';

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// The cron job sends the service-role JWT stored in vault as 'service_role_key'.
// That is a different (older) issue of the key than the runtime
// SUPABASE_SERVICE_ROLE_KEY, so a string comparison alone rejects cron -- this
// is exactly what took eleven brd-* functions down for five hours on
// 2026-09-07. Claims are never trusted on their own either: verify_jwt is false
// here, so an unsigned payload saying role=service_role proves nothing. The
// token is presented to GoTrue's admin API, which checks the signature.
async function isVerifiedServiceJwt(token: string): Promise<boolean> {
  if (!token) return false;
  const parts = token.split('.');
  if (parts.length !== 3) return false;
  try {
    const seg = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const claims = JSON.parse(atob(seg.padEnd(Math.ceil(seg.length / 4) * 4, '=')));
    if (claims?.role !== 'service_role') return false;
  } catch {
    return false;
  }
  if (!SB_URL) return false;
  try {
    const res = await fetch(`${SB_URL}/auth/v1/admin/users?page=1&per_page=1`, {
      headers: { apikey: token, Authorization: `Bearer ${token}` },
    });
    await res.body?.cancel();
    return res.status === 200;
  } catch {
    return false;
  }
}

Deno.serve(async (req: Request) => {
  // Config is checked here rather than at import so a misconfiguration is
  // reportable. Module-scope failure is what made the original bug invisible.
  const missing = [
    !SB_URL && 'SUPABASE_URL (or SB_URL)',
    !SB_KEY && 'SUPABASE_SERVICE_ROLE_KEY (or SB_SERVICE_ROLE_KEY)',
  ].filter(Boolean);
  if (missing.length) {
    return json({ ok: false, error: `missing configuration: ${missing.join(', ')}` }, 500);
  }

  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  let authorized = token !== '' && timingSafeEqual(token, SB_KEY);
  if (!authorized && token) authorized = await isVerifiedServiceJwt(token);
  if (!authorized) return json({ ok: false, error: 'unauthorized' }, 401);

  const sb = createClient(SB_URL, SB_KEY, { auth: { persistSession: false } });

  const { data: due, error } = await sb.from('audio_hub_pipeline')
    .select('id,title,series_id')
    .eq('status', 'scheduled')
    .lte('scheduled_at', new Date().toISOString())
    .limit(25);
  if (error) return json({ ok: false, error: error.message }, 500);
  if (!due || due.length === 0) return json({ ok: true, published: 0 });

  const results: Array<{ id: string; item_id?: string; error?: string }> = [];
  for (const p of due) {
    const job = await sb.from('audio_hub_jobs')
      .insert({ series_id: p.series_id, pipeline_id: p.id, kind: 'publish', status: 'running' })
      .select('id').single();
    const jobId = job.data?.id;
    const { data: itemId, error: pubErr } = await sb.rpc('audio_hub_publish_pipeline', { p_pipeline_id: p.id });
    if (pubErr) {
      await sb.from('audio_hub_pipeline').update({ status: 'failed', error: pubErr.message }).eq('id', p.id);
      if (jobId) await sb.from('audio_hub_jobs').update({ status: 'error', detail: pubErr.message }).eq('id', jobId);
      results.push({ id: p.id, error: pubErr.message });
      continue;
    }
    if (jobId) await sb.from('audio_hub_jobs').update({ status: 'ok', detail: 'published item ' + itemId }).eq('id', jobId);
    results.push({ id: p.id, item_id: itemId });
    if (TG_TOKEN && TG_CHAT) {
      await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chat_id: TG_CHAT, text: `🚀 Published: *${p.title}*`, parse_mode: 'Markdown' }),
      });
    }
  }
  return json({ ok: true, published: results.filter((r) => r.item_id).length, results });
});
