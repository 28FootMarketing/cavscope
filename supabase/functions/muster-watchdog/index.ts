import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Self-healing PRD-001 (.planning/selfheal/prds/PRD-001-incident-intake-and-watchdog.md):
// a fixed battery of cheap, read-only checks against MUSTER's own operational
// data, run every 10 minutes. Anything anomalous is reported through
// public.muster_engine_report_incident, which dedupes by fingerprint so a
// repeated signal bumps an existing muster.incidents row instead of opening
// a new one every cycle.
//
// This function NEVER writes to any business table and NEVER calls out to
// anything except muster_engine_report_incident. It has no code-repair
// capability of any kind -- see .planning/selfheal/ARCHITECTURE.md for why
// detection and repair are deliberately separate actors with separate
// credentials.
//
// Invocation (same shared-secret pattern as every other engine function):
//   Authorization: Bearer <anon key>
//   x-muster-secret: <vault muster_cron_secret>

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

async function reportIncident(fingerprint: string, source: string, severity: string, affectedOperation: string, evidence: Record<string, unknown>) {
  const { error } = await db.rpc("muster_engine_report_incident", {
    p_fingerprint: fingerprint,
    p_source: source,
    p_severity: severity,
    p_affected_operation: affectedOperation,
    p_affected_release: null,
    p_evidence: evidence,
  });
  if (error) throw new Error(`report_incident failed for ${fingerprint}: ${error.message}`);
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const { data: secret } = await db.rpc("muster_engine_secret");
  const provided = req.headers.get("x-muster-secret") ?? "";
  if (!secret || provided !== secret) return json({ error: "unauthorized" }, 401);

  const today = new Date().toISOString().slice(0, 10);
  let incidentsOpened = 0;
  const checksRun: string[] = [];

  // Check 1 (RP-05): any muster-* cron job run in the last 20 minutes that
  // did not succeed, or whose last run is older than 2x its own schedule
  // interval (a missed run leaves no job_run_details row at all, so this
  // has to be checked against cron.job.schedule, not just failure status).
  // cron.job_run_details/cron.job live outside PostgREST's exposed schemas,
  // so this runs via one RPC rather than a direct table read.
  checksRun.push("cron_failure");
  {
    const { data: failures, error } = await db.rpc("muster_engine_cron_health_check");
    if (error) throw new Error(`cron health check failed: ${error.message}`);
    for (const row of (failures ?? []) as Array<{ jobname: string; failure_count: number; missed: boolean }>) {
      if (row.failure_count > 0) {
        await reportIncident(`cron_failure:${row.jobname}:${today}`, "cron_failure", "critical", row.jobname, { failure_count: row.failure_count });
        incidentsOpened++;
      }
      if (row.missed) {
        await reportIncident(`cron_missed:${row.jobname}:${today}`, "cron_missed", "critical", row.jobname, { missed: true });
        incidentsOpened++;
      }
    }
  }

  // Checks 2-5: business-data anomalies, all via one RPC that returns a
  // structured summary (keeps this function free of raw SQL against
  // business tables -- it only ever calls RPCs, same as every other
  // MUSTER client).
  checksRun.push("scan_silent_failure", "commercial_grant_stuck", "alert_dead_letter", "engine_error_spike");
  {
    const { data: summary, error } = await db.rpc("muster_engine_watchdog_summary");
    if (error) throw new Error(`watchdog summary failed: ${error.message}`);
    const s = summary as {
      silent_scans: Array<{ scan_id: number; website_id: number; url: string }>;
      stuck_grants: Array<{ id: number; email: string; created_at: string }>;
      dead_letter_alerts: number;
      failed_scans_24h: number;
    };

    for (const scan of s.silent_scans ?? []) {
      await reportIncident(`scan_silent_failure:${scan.scan_id}`, "scan_silent_failure", "info", "muster.generate_sitrep / scan rule evaluation", scan);
      incidentsOpened++;
    }
    for (const grant of s.stuck_grants ?? []) {
      await reportIncident(`commercial_grant_stuck:${grant.id}`, "commercial_grant_stuck", "warning", "muster-stripe-webhook -> onboarding", grant);
      incidentsOpened++;
    }
    if ((s.dead_letter_alerts ?? 0) > 0) {
      await reportIncident(`alert_dead_letter:${today}`, "alert_dead_letter", "warning", "muster-alert-dispatch", { dead_letter_count: s.dead_letter_alerts });
      incidentsOpened++;
    }
    if ((s.failed_scans_24h ?? 0) > 0) {
      await reportIncident(`engine_error_spike:${today}`, "engine_error_spike", "info", "muster-scan", { failed_scans_24h: s.failed_scans_24h });
      incidentsOpened++;
    }
  }

  return json({ checks_run: checksRun.length, incidents_opened: incidentsOpened });
});
