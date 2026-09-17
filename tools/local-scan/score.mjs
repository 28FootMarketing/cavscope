/**
 * Posture score, reproduced from the database so the local runner and the
 * product agree on the number.
 *
 * Source of truth is muster.severity_weight / muster.posture_score /
 * muster.posture_band in
 * supabase/migrations/20260907223344_muster_012_helper_functions_sql.sql.
 * If those weights change, change them here and in that migration, or a local
 * scan and a real scan will report different postures for the same site.
 *
 * One difference is structural and cannot be fixed here: muster.posture_score()
 * sums every OPEN finding for a website, across all of its scans. This sums the
 * findings of the single scan it was handed. For a site's first scan the two are
 * identical; for a site with unresolved history the database number is lower.
 */

export const SEVERITY_WEIGHT = { critical: 25, high: 10, medium: 4, low: 1, info: 0 };
export const SEVERITY_ORDER = ["critical", "high", "medium", "low", "info"];

export function postureScore(findings) {
  const deductions = findings.reduce((n, f) => n + (SEVERITY_WEIGHT[f.severity] ?? 0), 0);
  return Math.max(0, 100 - deductions);
}

export function postureBand(score) {
  return score >= 85 ? "green" : score >= 60 ? "amber" : "red";
}

export function countBySeverity(findings) {
  const out = {};
  for (const s of SEVERITY_ORDER) out[s] = 0;
  for (const f of findings) out[f.severity] = (out[f.severity] ?? 0) + 1;
  return out;
}
