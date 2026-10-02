---
doc: features/join-security/00-INDEX
repo: c3
kind: feature-index
tier: B
anchored_to: e99b2ae
generated: 2026-10-02
---
# Join Security

This feature protects a session from someone guessing its way in. When an address sends wrong security numbers or tries session codes that don't exist, the server records it. Past a threshold it bans that address from creating or joining sessions. A ban lasts a short while at first, then longer each time, and at most until local midnight. An agent that is already inside a session keeps working from a banned address. Addresses on the allowlist are never banned. IPv6 clients are tracked by their whole network, not by the single address.

## Does this ticket belong here?

**Yes if it mentions:** banned IP, "banned until midnight", wrong secret / wrong security number, unknown session code, brute force, ban length or escalation, allowlist, unbanning an address, IPv6 users banned together (same /64), ban lasting the wrong time around DST or timezone, failed join history being purged, ban still in effect after a restart.
**UI labels:** `ip_banned`, `invalid_secret`, `unknown_code`, `C3_SECRET_TOLERANCE`, `C3_IPV6_PREFIX`, `C3_IP_ALLOWLIST`, `C3_TZ`
**Routes:** _(none of its own; it guards `create`/`join`, which belong to [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md))_
**No — go elsewhere if:**
- the session's own join lock (`joins_locked_at`, unlock, secret rotation) → [`session-lifecycle`](../session-lifecycle/00-INDEX.md). It is triggered from `lib/c3/sessions.ex:maybe_lock_joins` and counts with `lib/c3/security.ex:invalid_secret_ips`.
- the admin's ban list or unban button → [`admin-ui`](../admin-ui/00-INDEX.md)
- per-request rate limiting or client IP resolution behind a proxy → architecture, [request pipeline](../../architecture/01-request-pipeline-and-routing.md)
- ban/failure counters on the metrics endpoint → [`metrics`](../metrics/00-INDEX.md)

## Entry points

| Route | Page component | Module root |
|---|---|---|
| _(called from `lib/c3/sessions.ex:check_ban`, `lib/c3/sessions.ex:unknown_code` and `lib/c3/sessions.ex:invalid_secret`)_ | — | `lib/c3/security.ex:C3.Security` |
| Ban lookup on every `create`/`join` | — | `lib/c3/security/ban_cache.ex:C3.Security.BanCache` (ETS, no DB hit) |
| Daily purge | — | `lib/c3/security.ex:purge_history`, run by the sweeper |

## Traps

- **The DB row is the source of truth, but checks only read ETS.** After `lib/c3/security.ex:ban` you have to call `lib/c3/security.ex:cache_ban` *after the transaction commits*. If you skip it, the ban exists in the database but nobody enforces it until `lib/c3/security/ban_cache.ex:load` runs at the next boot.
- **`ip` stores the subject, not the address.** `ip_full` holds the exact address. Every count and lookup goes through `lib/c3/security/cidr.ex:subject`. A query on the raw address finds nothing for IPv6.
- **Allowlisting a network:** `lib/c3/security.ex:allowlisted?` uses `block_member?` for a `/` subject, so the *whole* /64 must be inside the allowlist. Allowlisting a single IPv6 host does not exempt its network.
- **Escalation is per local day.** `lib/c3/security.ex:secret_ban_until` steps through `@ban_steps` (60 s, 600 s, 3600 s), counting the subject's secret bans since `lib/c3/local_time.ex:day_start`. A ban in a *second* session the same day jumps straight to `next_midnight`. No ban ever runs past midnight.
- **The tolerance check is strict `>`.** `secret_failures` counts the failure that was just recorded, so the first `C3_SECRET_TOLERANCE` wrong secrets go unbanned. Failures from before the last unlock or rotation are excluded through `since` (`lib/c3/sessions.ex:last_reset_at`).
- **`lib/c3/security.ex:unban` returning `0` is not an error.** The ban may have just expired. It accepts a single address or a network and normalizes it to the subject form.
- **DST:** `lib/c3/local_time.ex:midnight` resolves a midnight that falls in a gap to the first instant after the gap, and an ambiguous one to its first occurrence. Every value it returns is UTC.
- **Purge window:** `lib/c3/security.ex:purge_history` deletes data older than `@history_days` (30). This includes ended bans, which also removes them from the daily escalation history (harmless, since escalation only looks at the current day).

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) | The `create`/`join` flow itself, secret verification, the `{:error, :ip_banned, until}` response |
| [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | Join lock, unlock, secret rotation |
| [`event-feed`](../event-feed/00-INDEX.md) | The `security_join_failed` event (appended in `lib/c3/sessions.ex:invalid_secret`) |
| [`admin-ui`](../admin-ui/00-INDEX.md) | Listing and lifting bans in the UI (wraps `lib/c3/security.ex:list_active_bans` / `unban`) |
| [`metrics`](../metrics/00-INDEX.md) | Exporting `[:ip, :banned]` / `[:join, :failed]` |

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | how a failed join becomes a ban, and how a ban is checked and lifted |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |

## Related

- Architecture: [data model](../../architecture/02-data-model-and-persistence.md), [processes](../../architecture/04-processes-and-background-work.md), [configuration](../../architecture/05-configuration-and-environments.md)
- Features: [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md), [`session-lifecycle`](../session-lifecycle/00-INDEX.md), [`admin-ui`](../admin-ui/00-INDEX.md)
