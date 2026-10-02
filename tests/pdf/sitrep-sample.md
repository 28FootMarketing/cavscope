# SITREP: Northstar Fintech

| | |
|---|---|
| Organization | Northstar Fintech (sample) |
| Target | https://northstar.example.test |
| Scan | #1, completed 2026-10-02 02:44 UTC |
| Engine | http-native-1.15.0 |
| Posture | 65 / 100 (amber) |

Prepared by CavScope. Every statement below cites a finding [F] or captured evidence [E] row.

## Board Report

- Overall website assurance posture is 65 of 100 (amber). [F486][F487][F488][F489][F491][+7 more][E3568]
- Posture fell from 66 to 65 since the previous report (-1). This scan added 1 new finding, reopened 0 and resolved 0. 
- The most severe open item is No SPF record (high). [F493]
- 12 open findings: 0 critical, 2 high, 2 medium, 7 low, 1 informational. [F486][F487][F488][F489][F491][+7 more]

## What This Scan Did Not Check

- CavScope reads this site over HTTP and DNS only. It does not execute JavaScript, so anything a page builds in the browser after load is not assessed.
- A clean result is evidence that these specific checks passed on this date. It is not a statement that the site is secure.

## Findings

Showing 3 of 3 open findings, most severe first.

- **No SPF record** (high, `EMAIL-001`): No v=spf1 TXT record at northstar.example.test. Nothing tells receiving mail servers which systems may send as this domain, so anyone can. [F493][E801][E813][E852][E1051][E1149][E1339][E1426][E1478][E1639][E2002][E2315][E2559][E2985][E3109][E3213][E3396][E3541][E3581]

- **No CAA record restricts who may issue certificates** (low, `SEC-015`): Any public certificate authority may therefore issue a certificate for this domain — and a mis-issued certificate is what makes a convincing interception possible. [F495][E801][E813][E852][E1051][E1149][E1339][E1426][E1478][E1639][E2002][E2315][E2559][E2985][E3109][E3213][E3396][E3541][E3581]

- **Terms link** (low, `PRIV-004`): Scanned 0 links; none contained "terms" or "tos" in its text or href. Unicode check: naïve café — “quoted” … → ok ✓ 日本語 🙂. [F1710][E801][E813][E852][E1051][E1149][E1339][E1426]

## Controls

73 of 100 derived controls met, 22 partial, 5 not met, 0 not assessed. A citation is not a test of the framework, and this is not an audit opinion.

- **NIST SP 800-53 Rev. 5 SC-17**: partial

- **NIST SP 800-53 Rev. 5 SC-18**: partial

- **NIST SP 800-53 Rev. 5 SC-19**: partial

- **NIST SP 800-53 Rev. 5 SC-20**: partial

- **NIST SP 800-53 Rev. 5 SC-21**: partial

- **NIST SP 800-53 Rev. 5 SC-22**: partial

## Plain English

- Right now any certificate company in the world is allowed to issue a certificate for your domain. Fix: Publish a CAA record, for example: example.com. IN CAA 0 issue "letsencrypt.org". Check every CA your organisation uses before publishing -- a CAA record that omits one will stop renewals. [F495][E801][E813][E852][E1051][E1149][E1339][E1426][E1478][E1639][E2002][E2315][E2559][E2985][E3109][E3213][E3396][E3541][E3581]

## Evidence Index

| Evidence | Kind | URL | HTTP | SHA-256 |
|---|---|---|---|---|
| E3567 | http_response | https://northstar.example.test/path/0 | 200 | a256644db9ca |
| E3568 | http_response | https://northstar.example.test/path/1 | 200 | a256644db9ca |
| E3569 | http_response | https://northstar.example.test/path/2 | 200 | a256644db9ca |
| E3570 | http_response | https://northstar.example.test/path/3 | 200 | a256644db9ca |
| E3571 | http_response | https://northstar.example.test/path/4 | 200 | a256644db9ca |
| E3572 | http_response | https://northstar.example.test/path/5 | 200 | a256644db9ca |
| E3573 | http_response | https://northstar.example.test/path/6 | 200 | a256644db9ca |
| E3574 | http_response | https://northstar.example.test/path/7 | 200 | a256644db9ca |
| E3575 | http_response | https://northstar.example.test/path/8 | 200 | a256644db9ca |
| E3576 | http_response | https://northstar.example.test/path/9 | 200 | a256644db9ca |
| E3577 | http_response | https://northstar.example.test/path/10 | 200 | a256644db9ca |
| E3578 | http_response | https://northstar.example.test/path/11 | 200 | a256644db9ca |
| E3579 | http_response | https://northstar.example.test/path/12 | 200 | a256644db9ca |
| E3580 | http_response | https://northstar.example.test/path/13 | 200 | a256644db9ca |
| E3581 | http_response | https://northstar.example.test/path/14 | 200 | a256644db9ca |
| E3582 | http_response | https://northstar.example.test/path/15 | 200 | a256644db9ca |
| E3583 | http_response | https://northstar.example.test/path/16 | 200 | a256644db9ca |
| E3584 | http_response | https://northstar.example.test/path/17 | 200 | a256644db9ca |
| E3585 | http_response | https://northstar.example.test/path/18 | 200 | a256644db9ca |
| E3586 | http_response | https://northstar.example.test/path/19 | 200 | a256644db9ca |
| E3587 | http_response | https://northstar.example.test/path/20 | 200 | a256644db9ca |
| E3588 | http_response | https://northstar.example.test/path/21 | 200 | a256644db9ca |
| E3589 | http_response | https://northstar.example.test/path/22 | 200 | a256644db9ca |
| E3590 | http_response | https://northstar.example.test/path/23 | 200 | a256644db9ca |
| E3591 | http_response | https://northstar.example.test/path/24 | 200 | a256644db9ca |
| E3592 | http_response | https://northstar.example.test/path/25 | 200 | a256644db9ca |
| E3593 | http_response | https://northstar.example.test/path/26 | 200 | a256644db9ca |
| E3594 | http_response | https://northstar.example.test/path/27 | 200 | a256644db9ca |
| E3595 | http_response | https://northstar.example.test/path/28 | 200 | a256644db9ca |
| E3596 | http_response | https://northstar.example.test/path/29 | 200 | a256644db9ca |
| E3597 | http_response | https://northstar.example.test/path/30 | 200 | a256644db9ca |
| E3598 | http_response | https://northstar.example.test/path/31 | 200 | a256644db9ca |
| E3599 | http_response | https://northstar.example.test/path/32 | 200 | a256644db9ca |
| E3600 | http_response | https://northstar.example.test/path/33 | 200 | a256644db9ca |
| E3601 | http_response | https://northstar.example.test/path/34 | 200 | a256644db9ca |
| E3602 | http_response | https://northstar.example.test/path/35 | 200 | a256644db9ca |
| E3603 | http_response | https://northstar.example.test/path/36 | 200 | a256644db9ca |
| E3604 | http_response | https://northstar.example.test/path/37 | 200 | a256644db9ca |
| E3605 | http_response | https://northstar.example.test/path/38 | 200 | a256644db9ca |
| E3606 | http_response | https://northstar.example.test/path/39 | 200 | a256644db9ca |
| E3607 | http_response | https://northstar.example.test/path/40 | 200 | a256644db9ca |
| E3608 | http_response | https://northstar.example.test/path/41 | 200 | a256644db9ca |
| E3609 | http_response | https://northstar.example.test/path/42 | 200 | a256644db9ca |
| E3610 | http_response | https://northstar.example.test/path/43 | 200 | a256644db9ca |
| E3611 | http_response | https://northstar.example.test/path/44 | 200 | a256644db9ca |
| E3612 | http_response | https://northstar.example.test/path/45 | 200 | a256644db9ca |
| E3613 | http_response | https://northstar.example.test/path/46 | 200 | a256644db9ca |
| E3614 | http_response | https://northstar.example.test/path/47 | 200 | a256644db9ca |
| E3615 | http_response | https://northstar.example.test/path/48 | 200 | a256644db9ca |
| E3616 | http_response | https://northstar.example.test/path/49 | 200 | a256644db9ca |
| E3617 | http_response | https://northstar.example.test/path/50 | 200 | a256644db9ca |
| E3618 | http_response | https://northstar.example.test/path/51 | 200 | a256644db9ca |
| E3619 | http_response | https://northstar.example.test/path/52 | 200 | a256644db9ca |
| E3620 | http_response | https://northstar.example.test/path/53 | 200 | a256644db9ca |
| E3621 | http_response | https://northstar.example.test/path/54 | 200 | a256644db9ca |
| E3622 | http_response | https://northstar.example.test/path/55 | 200 | a256644db9ca |
| E3623 | http_response | https://northstar.example.test/path/56 | 200 | a256644db9ca |
| E3624 | http_response | https://northstar.example.test/path/57 | 200 | a256644db9ca |
| E3625 | http_response | https://northstar.example.test/path/58 | 200 | a256644db9ca |
| E3626 | http_response | https://northstar.example.test/path/59 | 200 | a256644db9ca |
