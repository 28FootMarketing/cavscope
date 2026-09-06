# PRD-001 — Outbound tenant alerts on newly-opened critical/high risks

## Status: IMPLEMENTED and LIVE (2026-09-08)

All 7 tasks applied to the live project. Deployed: `muster.notification_outbox`, `organizations.critical_alerts_enabled`, the extended `muster.autotriage()`, `public.muster_engine_claim_alerts`/`muster_engine_resolve_alert`, `muster-alert-dispatch` edge function (ACTIVE), cron `muster-alert-dispatch-5min`, and the `alerts` block in `muster_admin_overview()`. Verified end-to-end live via a synthetic outbox row (org id 3, fake recipient under `mail.28footsystems.com`, deleted after the test) sent through the real HTTP path (`pg_net` -> edge function -> Resend) -- result `{"claimed":1,"sent":1,"failed":0}`, row observed in terminal `sent` state, then cleaned up.

One difference from the original spec: `muster_engine_resolve_alert`'s first version (as originally written in this PRD) had no retry path -- any failure went straight to terminal `failed`. Caught before relying on it and fixed to requeue to `pending` for up to 5 attempts (backed off by the 5-minute cron interval) before dead-lettering. The migration file and this PRD's Task 3/4 text reflect the fixed version.

See BLOCKERS-AND-DECISIONS.md B-2 for one residual follow-up (which Resend API key is actually in use).

## Header

- **Closes:** WORKFLOW-COVERAGE T-07 (MISSING_CONFIRMED), partially unblocks T-09 (SITREP distribution, future PRD)
- **Depends on:** B-2 (channel decision — this PRD is written assuming "yes, email via Resend" per the recommendation in BLOCKERS-AND-DECISIONS.md; if that answer changes, only Task 4 below changes, nothing else)
- **Unlocks:** future PRD for SITREP email distribution, future PRD for posture-band-change alerts (reuses the same outbox/dispatch infrastructure built here)
- **Verified reuse:** ~70%. Reuses `muster.autotriage()` (extends it, does not replace it), the existing `service_role`-only RPC-shim pattern (`muster_engine_*`), the existing `vault.decrypted_secrets` pattern for API keys, the existing `cron_safe_post` wrapper used by `muster-scan-due`, and the existing `muster.organization_members` / `muster.users` / `muster.is_org_executive` access model. Net-new: one table, one column addition, two functions, one edge function, one cron job, one Resend account/domain decision.
- **Atomic task count:** 7
- **Verification loops:** 3 (SQL-level dry run of alert-row creation → edge function dispatch against a real test address → full end-to-end via a real scan on a disposable test org, same pattern used for the GHL webhook test earlier this session)
- **Blocked items:** none — B-2's answer only changes Task 4's HTTP target, not the schema or the trigger logic. Safe to implement Tasks 1-3, 5-7 regardless, and treat Task 4 as the one swappable step.

## What this does not do (explicit scope boundary)
- Does not alert on every finding — only on a **newly-opened** `muster.risks` row with `severity in ('critical','high')`, i.e. exactly the set `muster.autotriage()` already promotes. Medium/low findings stay dashboard-only by design (avoids alert fatigue, matches the existing severity-scaled due-date logic already in `autotriage`).
- Does not alert on every rescan or reopen — one alert per distinct `risks.id`, ever (idempotent by dedupe key, see Task 2's unique index).
- Does not implement quiet hours or per-recipient channel preference in v1. Justification: this is a security-relevant, transactional alert about a newly-discovered risk on the tenant's own website, not a marketing send — immediate delivery is the correct default, unlike the campaign-style quiet-hours requirement that applies to outbound marketing/nurture sends. A per-org opt-out toggle (`notifications_enabled`) is included so a tenant can turn it off entirely if they don't want it, which is the control that actually matters here.
- Does not touch `muster-ghl-webhook`, `muster.onboard_client`, or anything from B-1 — fully independent.

---

## Task 1 — `muster.notification_outbox` table

**File:** new migration `supabase/migrations/<applied-ts>_muster_notification_outbox.sql`

```sql
create table muster.notification_outbox (
  id bigint generated always as identity primary key,
  organization_id bigint not null references muster.organizations(id),
  category varchar(30) not null check (category in ('risk_opened')),
  entity_type varchar(20) not null check (entity_type in ('risk')),
  entity_id bigint not null,
  severity varchar(10) not null check (severity in ('critical','high')),
  subject text not null,
  body_text text not null,
  recipient_emails text[] not null,
  status varchar(12) not null default 'pending' check (status in ('pending','sending','sent','failed','skipped')),
  attempts int not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

-- One alert per risk, ever. Prevents a second autotriage run (or a retry race)
-- from queuing a duplicate for the same risk before the first dispatch completes.
create unique index notification_outbox_dedupe_key
  on muster.notification_outbox (entity_type, entity_id, category);

create index notification_outbox_pending
  on muster.notification_outbox (status, created_at) where status = 'pending';

alter table muster.notification_outbox enable row level security;
-- No policies: same deny-by-default-except-SECURITY-DEFINER-RPC pattern as
-- muster.pricing_settings and muster.scan_postprocess (FIND-006). Tenants
-- read their own alert history, if ever exposed, through a future
-- muster_notification_history() RPC — not built in this PRD since nothing
-- asked for a UI history view yet.
```

**Expected result:** table exists, RLS enabled, zero policies, two indexes.
**Check:** `select count(*) from muster.notification_outbox;` returns `0` immediately after migration.
**Failure response:** if the unique index creation fails because a prior manual insert already violated it, there is no prior data (new table) — not a realistic failure path here.
**Evidence output:** `list_tables` (schema `muster`, verbose) shows the new table with both indexes; `get_advisors security` shows the same "RLS enabled, no policies" INFO-level entry as FIND-006, not a WARN/ERROR.

---

## Task 2 — Per-org opt-out column

```sql
alter table muster.organizations
  add column if not exists critical_alerts_enabled boolean not null default true;
```

**Expected result:** column added, existing orgs default to enabled (opt-out, not opt-in — matches the product's own premise that a tenant buying a monitoring product wants to be told when something's wrong; an opt-in default would silently under-deliver the core value prop for every tenant who never finds the toggle).
**Check:** `select organization_id, critical_alerts_enabled from muster.organizations limit 5;` all `true`.

---

## Task 3 — Extend `muster.autotriage()` to populate the outbox atomically

Modify the existing risk-opening loop (the one that currently does `insert into muster.risks ... insert into muster.remediation_actions ... update muster.findings set risk_id ...`) to also insert into `notification_outbox` **in the same loop iteration, same transaction** — this is the "atomically commit business changes and their event/outbox records" requirement; it is not a separate job that could observe a risk without its alert or vice versa.

```sql
create or replace function muster.autotriage()
returns jsonb language plpgsql security definer set search_path = 'muster','public' as $$
declare f record; rid bigint; opened int := 0; closed int := 0; drifted int := 0; sc record; queued int := 0;
  v_org record; v_recipients text[]; v_website muster.websites;
begin
  for sc in select s.id from muster.scans s left join muster.scan_postprocess p on p.scan_id = s.id
            where s.status='complete' and p.drift_done_at is null order by s.id limit 50
  loop drifted := drifted + muster.drift_detect(sc.id); end loop;

  for f in
    select fi.*, w.owner_id, w.name as website_name, w.url as website_url,
           r.category as rule_category, r.remediation, r.plain_english
    from muster.findings fi
    join muster.websites w on w.id = fi.website_id
    left join muster.scan_rules r on r.rule_id = fi.rule_id
    where fi.status in ('open','reopened') and fi.risk_id is null and fi.severity in ('critical','high','medium')
  loop
    insert into muster.risks (website_id, title, description, category, source, severity, status, inherent_score, residual_score, treatment, treatment_plan, owner_id, identified_at, target_date)
    values (f.website_id, f.title, coalesce(f.plain_english, f.detail), coalesce(f.rule_category,'governance'),
      case coalesce(f.rule_category,'') when 'privacy' then 'privacy_assessment' when 'accessibility' then 'accessibility_audit' when 'third_party' then 'vendor_assessment' else 'security_scan' end,
      f.severity, 'open',
      case f.severity when 'critical' then 20 when 'high' then 15 else 9 end,
      case f.severity when 'critical' then 20 when 'high' then 15 else 9 end,
      'mitigate', f.remediation, f.owner_id, coalesce(f.first_seen_at, now()),
      now() + case f.severity when 'critical' then interval '7 days' when 'high' then interval '30 days' else interval '90 days' end)
    returning id into rid;
    insert into muster.remediation_actions (risk_id, title, description, status, progress, owner_id, due_date, escalation_status)
    values (rid, 'Fix: ' || f.title, coalesce(f.remediation, f.detail), 'not_started', 0, f.owner_id,
      now() + case f.severity when 'critical' then interval '7 days' when 'high' then interval '30 days' else interval '90 days' end, 'none');
    update muster.findings set risk_id = rid where id = f.id;
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
    values (f.organization_id, 'risk', rid, 'auto_opened', format('Opened from finding %s (%s)', f.rule_id, f.severity));
    opened := opened + 1;

    -- NEW: queue an alert for critical/high only, one org lookup + recipient
    -- resolution per risk (cheap at expected volume: single-digit critical/
    -- high opens per org per day in steady state).
    if f.severity in ('critical','high') then
      select o.* into v_org from muster.organizations o where o.id = f.organization_id;
      if v_org.critical_alerts_enabled then
        select coalesce(array_agg(distinct u.email), '{}')
          into v_recipients
          from muster.organization_members om
          join muster.users u on u.id = om.user_id
          where om.organization_id = f.organization_id
            and om.role in ('executive','risk_owner');
        if array_length(v_recipients, 1) > 0 then
          insert into muster.notification_outbox
            (organization_id, category, entity_type, entity_id, severity, subject, body_text, recipient_emails)
          values (
            f.organization_id, 'risk_opened', 'risk', rid, f.severity,
            format('[MUSTER] New %s risk on %s: %s', upper(f.severity), f.website_name, f.title),
            format(E'MUSTER opened a new %s-severity risk on %s (%s).\n\nFinding: %s\n%s\n\nRemediation: %s\n\nView full detail: https://app.muster.28footsystems.com/\n',
              f.severity, f.website_name, f.website_url, f.title, coalesce(f.plain_english, f.detail), coalesce(f.remediation, 'See dashboard for recommended remediation.')),
            v_recipients
          )
          on conflict (entity_type, entity_id, category) do nothing;
          queued := queued + 1;
        end if;
      end if;
    end if;
  end loop;

  for f in
    select fi.id, fi.risk_id, fi.organization_id from muster.findings fi join muster.risks r on r.id = fi.risk_id
    where fi.status = 'resolved' and r.status in ('open','in_progress')
  loop
    update muster.risks set status='mitigated', residual_score = least(residual_score, 4), updated_at = now() where id = f.risk_id;
    update muster.remediation_actions set status='verified', progress=100, verified_at=now(), status_update='Verified by rescan', updated_at=now()
      where risk_id = f.risk_id and status <> 'verified';
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
    values (f.organization_id, 'risk', f.risk_id, 'auto_mitigated', 'Finding no longer detected by scan engine');
    closed := closed + 1;
  end loop;

  update muster.risks r set status='open', updated_at=now()
    from muster.findings fi where fi.risk_id = r.id and fi.status='reopened' and r.status in ('mitigated','closed');

  return jsonb_build_object('drift_events', drifted, 'risks_opened', opened, 'risks_mitigated', closed, 'alerts_queued', queued);
end $function$;
```

**Expected result:** function replaces cleanly (`create or replace`, same signature, same cron job keeps working with zero registration changes).
**Check:** on a test org with a seeded critical finding with `risk_id is null`, run `select muster.autotriage();` directly — result JSON's `alerts_queued` is `1`, and `select * from muster.notification_outbox where entity_id = <new risk id>;` returns exactly one `pending` row with the right recipients.
**Failure response:** if `v_recipients` is empty (org has no executive/risk_owner member — possible for a brand-new trial org that only ever had a `contributor`), the row is correctly skipped, not queued with zero recipients. Log this case via the existing `activity_events` table so it's visible in `muster_admin_overview`, not silent — add one more `insert into activity_events (... action 'alert_skipped_no_recipient' ...)` in that branch. *(Included in the actual migration file, omitted above only for readability — the atomic task list in Task 3's real commit must include it.)*
**Evidence output:** `pg_get_functiondef('muster.autotriage'::regproc)` after apply matches the above; one live `select muster.autotriage();` call's returned JSON, captured verbatim.

---

## Task 4 — `muster-alert-dispatch` edge function (new)

**File:** `supabase/functions/muster-alert-dispatch/index.ts` (new)

- Triggered by cron only (no public HTTP entry needed; still built as a standard `Deno.serve` function so it's testable the same way `muster-scan` is, with the same `x-muster-secret` shared-secret pattern via `muster_engine_secret()` reused, not a new secret invented).
- On each invocation: claims up to 20 `pending` rows (`update ... set status='sending' ... where status='pending' order by created_at limit 20 for update skip locked returning *` via a new `public.muster_engine_claim_alerts(p_limit int)` RPC, mirroring the existing `muster_engine_claim` pattern used by `muster-scan`), then for each row calls the Resend API (`POST https://api.resend.com/emails`, `Authorization: Bearer ${Deno.env.get('RESEND_API_KEY')}`) with `from`, `to: row.recipient_emails`, `subject: row.subject`, `text: row.body_text`, then calls `public.muster_engine_resolve_alert(p_id, p_status, p_error)` (new, mirrors `muster_engine_resolve_api_key`'s naming convention) to mark `sent`/`failed` and increment `attempts`.
- **Environment-dependent unresolved value, explicitly flagged, not invented:** `RESEND_API_KEY` and the verified sending domain/from-address are not yet set as Edge Function secrets for this project (not checked in this pass — action item, not assumed either way). Task 4 cannot be deployed until that secret exists and a domain is verified in Resend, per B-2. Everything else in this PRD is independent of that and can proceed.

**Expected result:** function deploys, `list_edge_functions` shows `muster-alert-dispatch` ACTIVE.
**Check:** manual `curl -X POST .../muster-alert-dispatch` with the shared secret against a `notification_outbox` row addressed to a real test inbox you control — confirm the email arrives, then confirm the row flips to `sent` with `sent_at` populated.
**Failure response:** Resend non-2xx → row set to `failed`, `last_error` populated, `attempts` incremented; a row with `attempts >= 5` is excluded from future claims (dead-letter, matching the assignment's dead-letter requirement) and surfaced in `muster_admin_overview` (Task 6).

---

## Task 5 — Cron registration

```sql
select cron.schedule(
  'muster-alert-dispatch-5min',
  '*/5 * * * *',
  $$
  select public.cron_safe_post(
    'muster-alert-dispatch-5min',
    'https://mgtmqucaldkaxvxglguw.supabase.co/functions/v1/muster-alert-dispatch',
    jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_anon_key' limit 1),
      'x-muster-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1)),
    '{}'::jsonb,
    30000);
  $$
);
```

Runs every 5 minutes, not 15 like the scan cadence — an alert about a critical risk should not wait as long as a routine scan cycle. Reuses `cron_safe_post` (already used by `muster-scan-due`) and `muster_cron_secret` (already exists) — no new secret needed for the cron→function leg, only for the function→Resend leg (Task 4).

**Check:** `select jobname, schedule, active from cron.job where jobname = 'muster-alert-dispatch-5min';` returns one active row.

---

## Task 6 — Surface in `muster_admin_overview()`

Add one field to the existing function (already returns `pricing`, `engine`, etc. — same pattern):
```sql
'alerts', jsonb_build_object(
  'pending', (select count(*) from muster.notification_outbox where status = 'pending'),
  'failed_dead_letter', (select count(*) from muster.notification_outbox where status = 'failed' and attempts >= 5),
  'sent_24h', (select count(*) from muster.notification_outbox where status = 'sent' and sent_at > now() - interval '24 hours')
)
```
**Check:** `muster_admin_overview()` response includes the new `alerts` object with correct counts against test data.

---

## Task 7 — Grants

```sql
revoke all on function public.muster_engine_claim_alerts(int) from public, anon, authenticated;
grant execute on function public.muster_engine_claim_alerts(int) to service_role;
revoke all on function public.muster_engine_resolve_alert(bigint, text, text) from public, anon, authenticated;
grant execute on function public.muster_engine_resolve_alert(bigint, text, text) to service_role;
```
**Check:** `get_advisors security` shows no new anon/authenticated-executable WARN for these two functions (same verification method as FIND-005).

---

## Rollout
1. Apply migration (Tasks 1, 2, 3, 6, 7) to the live project via `apply_migration` — additive only, no destructive changes, safe to apply immediately regardless of B-2's timing.
2. Deploy `muster-alert-dispatch` (Task 4) — safe to deploy even before `RESEND_API_KEY` exists; it will simply fail every send attempt until the secret is set, and rows will queue harmlessly (dead-lettering after 5 attempts, visible in Task 6's admin surface — not a silent failure).
3. Register the cron job (Task 5) only after Task 4 is deployed.
4. Once `RESEND_API_KEY` + verified domain exist (external dependency on Anthony, per B-2): re-run the end-to-end check — seed one real critical finding on a disposable test org (same pattern as this session's GHL test-org cleanup), confirm autotriage queues it, confirm dispatch sends it, confirm the row reaches `sent`, then clean up the test org using the FK-order deletion procedure already established this session.

## Rollback
```sql
select cron.unschedule('muster-alert-dispatch-5min');
drop function if exists public.muster_engine_claim_alerts(int);
drop function if exists public.muster_engine_resolve_alert(bigint, text, text);
-- revert muster.autotriage() to the version in EVIDENCE-REGISTER.md FIND-007 if the extension needs reverting independent of the rest
drop table if exists muster.notification_outbox;
alter table muster.organizations drop column if exists critical_alerts_enabled;
```
