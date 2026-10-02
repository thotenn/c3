---
doc: features/join-security/00-INDEX
repo: c3
kind: feature-index
tier: B
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Join Security

Join security guards the front door of a session: who may create a session or join one with a code and security number. It records every failed join. An IP that sends one wrong security number is banned from creating and joining until the next local midnight, and so is an IP that guesses too many unknown codes in a day. A session locks itself against new joins once enough different IPs have failed its secret. Agents that already joined are not affected and keep working, even from a banned IP. Operators can exempt trusted networks and lift bans by hand.

## Does this ticket belong here?

**Yes if it mentions:** an IP got banned, "banned until midnight", a ban that lasts too long or ends at the wrong hour (time zone, daylight saving), a failed join log, wrong security number, brute-forcing session codes, too many unknown codes, the allowlist, an IP that should never be banned, IPv6 or IPv4-mapped addresses not matching, lifting a ban, a ban that comes back after it was lifted, old security history being purged.
**UI labels:** `ip_banned`, `invalid_secret`, `unknown_code`, `session_closed`, `joins_locked`, `C3_TZ`, `C3_IP_ALLOWLIST`, `C3_UNKNOWN_CODE_LIMIT`, `C3_JOIN_LOCK_IPS`
**Routes:** _(undetermined)_ — this feature exposes no route of its own. It runs inside the create/join calls of [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) and [`mcp-server`](../mcp-server/00-INDEX.md).
**No — go elsewhere if:**
- the join/create flow itself (the code format, secret verification, issuing tokens) → [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md)
- unlocking a locked session, rotating its secret, closing a session → [`session-lifecycle`](../session-lifecycle/00-INDEX.md)
- the ban list screen or the unban button → [`admin-ui`](../admin-ui/00-INDEX.md)
- the `join.failed` / `ip.banned` counters → [`metrics`](../metrics/00-INDEX.md)
- the `security_join_failed` / `session_joins_locked` events the watcher sees → [`event-feed`](../event-feed/00-INDEX.md)

## Entry points

| Entry | Symbol | Notes |
|---|---|---|
| Ban check before create/join | `lib/c3/security.ex:banned_until` | Allowlist first, then ETS; it never queries the database |
| Record a failure | `lib/c3/security.ex:record_failure` | Truncates `attempted_code` to 32 characters before the changeset validates it |
| Ban an IP | `lib/c3/security.ex:ban` | Returns `nil` for an allowlisted IP; the caller must call `cache_ban/1` **after** the transaction commits |
| Lift a ban | `lib/c3/security.ex:unban` | Sets `lifted_at` and deletes the ETS entry; returning `0` is not an error |
| Unknown-code threshold | `lib/c3/security.ex:unknown_codes_today` | Counts from the **local** day start, not the last 24 h |
| Session lock threshold | `lib/c3/security.ex:invalid_secret_ips` | Counts distinct IPs; `since` = `nil` means ever |
| History purge | `lib/c3/security.ex:purge_history` | 30 days (`@history_days`); called by the sweeper |
| ETS mirror | `lib/c3/security/ban_cache.ex:C3.Security.BanCache` | Loads at boot (`handle_continue(:load)`), sweeps expired entries every hour |
| CIDR matching | `lib/c3/security/cidr.ex:member?` | Also used by the trusted proxy config, outside this feature |
| Day boundaries | `lib/c3/local_time.ex:next_midnight`, `lib/c3/local_time.ex:day_start` | Both return UTC |

## Traps

- **`ip_bans` is the source of truth; ETS is only a mirror.** A ban inserted without `lib/c3/security.ex:cache_ban` takes effect only after a restart, when `lib/c3/security/ban_cache.ex:load` runs. A ban cached before the transaction commits would survive a rollback. The callers in `lib/c3/sessions.ex` cache the ban after `Repo.transaction` returns, for this reason.
- **`BanCache.put` keeps the later expiry** (`lib/c3/security/ban_cache.ex:put`). `unban` removes the whole ETS entry, and in the table it lifts every ban of that IP that is still in force. A new ban for the same IP after an unban starts clean.
- **A single wrong secret bans the IP.** `invalid_secret` in `lib/c3/sessions.ex` calls `Security.ban` unconditionally. Only unknown codes have a threshold (`unknown_code_limit`).
- **The ban scope is create and join only.** Token-authenticated calls never consult `banned_until` (see `lib/c3/security.ex:C3.Security` moduledoc).
- **The allowlist is checked twice:** at ban time (`lib/c3/security.ex:ban`) and at check time (`lib/c3/security.ex:banned_until`). An IP added to `C3_IP_ALLOWLIST` after it was banned is let through even though its row stays active.
- **IPv4-mapped IPv6 (`::ffff:a.b.c.d`) is treated as IPv4** by `lib/c3/security/cidr.ex:parse_ip`. An IPv4 allowlist entry matches it.
- **`CIDR.member?` re-parses every CIDR string on each call** (`lib/c3/security/cidr.ex:parse!`) and raises on an invalid one. The config validates the blocks at boot, so this does not fail at runtime.
- **Midnight in a DST gap** resolves to the first instant after the gap. An ambiguous midnight resolves to its first occurrence (`lib/c3/local_time.ex:midnight`). Tests that pass a `tz` explicitly bypass `C3.Config`.
- **`JoinFailure` rows outlive their session**: `session_id` becomes `NULL` on purge (`lib/c3/security/join_failure.ex:C3.Security.JoinFailure`). Unknown-code failures never have a session.
- **`IpBan.reason` includes `:admin`** (`lib/c3/security/ip_ban.ex:reason`), but no caller in this scope bans with it. Where it is produced is _(undetermined)_.

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) | The join flow that calls this feature, `check_ban`, the dummy verify on an unknown code, `maybe_lock_joins` (all in `lib/c3/sessions.ex`) |
| [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | `joins_locked_at`, unlocking a session, secret rotation (both reset the lock's failure window) |
| [`admin-ui`](../admin-ui/00-INDEX.md) | The ban list and the unban action (`lib/c3/admin.ex` wraps `Security.unban/1`) |
| [`metrics`](../metrics/00-INDEX.md) | `C3.Metrics.emit` and the ban gauges |
| _(no sibling feature)_ | Resolving the client IP behind the reverse proxy: `lib/c3_web/plugs/real_ip.ex` uses `CIDR` but is not part of this feature |
| _(configuration architecture doc)_ | `C3_TZ`, `C3_IP_ALLOWLIST` and the threshold values, defined in `lib/c3/config.ex` |
| _(background processes architecture doc)_ | The sweeper that schedules `purge_history` (`lib/c3/sweeper.ex`) |

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | how a failed join becomes a ban or a session lock, and how a ban is checked and lifted |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |

## Related

- Features: [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md), [`session-lifecycle`](../session-lifecycle/00-INDEX.md), [`admin-ui`](../admin-ui/00-INDEX.md), [`metrics`](../metrics/00-INDEX.md), [`event-feed`](../event-feed/00-INDEX.md)
