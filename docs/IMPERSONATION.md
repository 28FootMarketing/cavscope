# Admin impersonation protocol

A MUSTER super admin can open a **read-only, time-boxed, reason-bound** session to see what one
user sees. This document is the protocol: what it does, what it deliberately cannot do, and what
gets recorded.

Implementation: [`muster_038`](../supabase/migrations/20260908061350_muster_038_admin_impersonation_with_audit_protocol.sql),
grant fix in [`muster_039`](../supabase/migrations/20260908061750_muster_039_revoke_anon_from_impersonation_rpcs.sql).

## The central decision: no session swap

**No token is ever minted for the target user. `auth.uid()` never changes.**

The admin stays themselves for the whole session. What the session grants is authorisation for
super-admin-only `SECURITY DEFINER` reads to return one specific user's view.

The alternative — generating a real session for the target, which is what most products mean by
"impersonate" — was rejected for three reasons:

| | Session swap | What MUSTER does |
|---|---|---|
| Attribution | a real credential exists for someone else's account; RLS and the logs cannot tell it from that person signing in | the admin is always the admin; the target's account is never authenticated |
| Revocation | the token stays valid until it expires | authorisation is re-checked on every call, so ending a session cuts access off on the next one |
| Writes | anything the admin does is attributed to the tenant | there is no write path at all |

## Read only, and it must stay that way

Nothing in this feature can write tenant data as the target. There is no "act as" write path and one
must not be added. The moment an admin can change a tenant's data under the tenant's name, the audit
trail stops being able to answer *who did this*, which is the only question it exists to answer.

## Guardrails, all enforced in SQL

The UI is not what an attacker uses, so every rule lives in the database.

| Rule | Enforced by |
|---|---|
| Super admin only | `muster.is_super_admin()` at the top of all five functions |
| Cannot impersonate another super admin | explicit role check — blocks lateral escalation into a peer's audit trail |
| Cannot impersonate yourself | check, plus the `impersonation_no_self` table constraint |
| Reason required, 10 characters minimum | function check, plus a column `check` constraint |
| 1 to 60 minutes | function check, plus the `impersonation_bounded` constraint |
| One live session per admin | `impersonation_one_active_per_admin` partial unique index |
| Expiry needs no sweeper | `muster.active_impersonation()` evaluates `expires_at > now()` on every call |
| Window cannot be tampered into nonsense | `impersonation_bounded` also rejects a direct UPDATE that would move `expires_at` before `started_at` or beyond 60 minutes |
| Audit tables unreachable from PostgREST | RLS on, zero policies, no grant to `anon` or `authenticated` |

## What gets recorded, and who can see it

Three places, on purpose:

1. **`muster.impersonation_sessions`** — who, whom, why, when, until when, how it ended.
2. **`muster.impersonation_events`** — append-only, one row per action taken under the session. No
   update or delete grant exists on this table.
3. **`muster.activity_events` in the target's own organization** — `admin_impersonation_started`
   (carrying the reason, verbatim) and `admin_impersonation_ended`.

Point 3 is the one that matters ethically: **the tenant can see it happened, and why.** Impersonation
is visible to the people being impersonated, not only to us.

One limitation, stated rather than hidden: a user who belongs to **no organization** has no tenant
feed to write to, so for them only 1 and 2 exist. Sessions are still fully recorded; there is just no
tenant-facing surface to show it on.

## The API

| Function | Does |
|---|---|
| `muster_admin_impersonate_start(target_user_id, reason, minutes default 30)` | opens a session; returns session id, target, org, expiry |
| `muster_admin_impersonate_status()` | the caller's live session and seconds remaining, or `{active:false}` |
| `muster_admin_impersonated_view()` | the target's workspace view; logs the access |
| `muster_admin_impersonate_end()` | closes it; idempotent, so a double-end is not an error |
| `muster_admin_impersonation_log(limit default 50)` | the audit trail |

## Verified

Three assertion blocks, all rolled back, all against the live database:

- **Guards** — short reason, 0 and 61 minutes, self, a peer super admin, an unknown user, and a second
  concurrent session were each refused with the right SQLSTATE. The happy path returned
  `read_only: true`, status reflected it, and the view was logged.
- **Authorization and expiry** — a non-super-admin was refused by all five functions; an anonymous
  caller was refused; an expired session read `active:false` and its next view raised 42501; opening a
  new session closed the expired one out with `ended_reason = 'expired'`.
- **Tenant visibility** — the target's real org and role appeared in the view, and exactly two
  `admin_impersonation_*` rows landed in that org's activity feed, the first carrying the reason.

## A grant trap worth remembering

`muster_038` claimed anon could not call these. It was wrong, and `muster_039` fixed it.

Supabase installs `ALTER DEFAULT PRIVILEGES` granting EXECUTE on new functions in `public` to **anon
and authenticated as named roles**. `revoke ... from public` removes the PUBLIC pseudo-role grant and
leaves the named one intact, so the functions shipped with `anon=X` while every pre-existing
`muster_admin_*` function had only `postgres`, `authenticated`, `service_role`.

It was never a live hole — `is_super_admin()` is false without an `auth.uid()`, and an anonymous call
was verified to raise 42501 — but the claim in the comment did not match reality.

**To strip anon from a function in `public` on Supabase, revoke from `anon` by name.**

## Not built

No UI. The RPCs, the guardrails and the audit trail are the security-bearing half and they are done;
an admin console panel is presentation on top of them and is a smaller, lower-risk piece of work.
