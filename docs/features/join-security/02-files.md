---
doc: features/join-security/02-files
repo: c3
kind: feature-files
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Join Security — files

The modules here hold the security records and the queries over them: failed joins, IP bans, the ETS ban mirror, CIDR matching and local-day boundaries. They do not decide when a ban happens. That decision lives in the join flow, in `lib/c3/sessions.ex:unknown_code`, `lib/c3/sessions.ex:invalid_secret` and `lib/c3/sessions.ex:maybe_lock_joins`. Those functions call `lib/c3/security.ex:record_failure`, then `lib/c3/security.ex:ban`, and after the transaction commits, `lib/c3/security.ex:cache_ban`. The per-session join lock (`joins_locked_at`) is set there too, from the count returned by `lib/c3/security.ex:invalid_secret_ips`. The module doc of `lib/c3/security.ex` mentions the lock, but none of the lock logic is in this folder. A ban stops only `create` and `join`. An agent that already joined keeps working from a banned IP, because it authenticates with its token.

**Owned globs:** `lib/c3/security.ex`, `lib/c3/security/*.ex`, `lib/c3/local_time.ex`

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/security.ex` | `C3.Security.banned_until/2` | context | Checks bans on the hot path. An allowlisted IP is never banned; for any other IP it reads `BanCache` and never the database | a ban lets a `create`/`join` through when it shouldn't, or blocks one when it shouldn't |
| `lib/c3/security.ex` | `C3.Security.ban/4` | context | Inserts an `IpBan` that lasts until the next local midnight. Returns `nil` for an allowlisted IP and emits `[:ip, :banned]` | changing how long a ban lasts, or what gets recorded with it |
| `lib/c3/security.ex` | `C3.Security.cache_ban/1` | context | Copies a committed ban into ETS and accepts `nil` | adding a new code path that bans. You must call this after the commit, or the ban only takes effect at the next boot |
| `lib/c3/security.ex` | `C3.Security.record_failure/3` | context | Inserts a `JoinFailure`, cuts `attempted_code` to 32 characters, and emits `[:join, :failed]` | adding a failure reason, or capturing more request metadata |
| `lib/c3/security.ex` | `C3.Security.unknown_codes_today/2` | context | Counts the `:unknown_code` failures from one IP since the local day started | changing the unknown-code threshold window (the limit itself is `unknown_code_limit` in config) |
| `lib/c3/security.ex` | `C3.Security.invalid_secret_ips/2` | context | Counts the distinct IPs that sent a wrong secret to a session after `since`; `nil` means since the start | changing what counts toward the join lock |
| `lib/c3/security.ex` | `C3.Security.unban/2` | context | Sets `lifted_at` on every ban of the IP that is still in force, then deletes the IP from `BanCache`. Returning `0` is not an error | changing how admin unbans behave |
| `lib/c3/security.ex` | `C3.Security.purge_history/1` | context | Deletes failures, and bans that ended, older than `@history_days` (30) | changing how long security history is kept |
| `lib/c3/security.ex` | `C3.Security.list_active_bans/1` | context | Returns the bans that have not expired and were not lifted | admin ban listings, or the boot load of the cache |
| `lib/c3/security.ex` | `C3.Security.allowlisted?/1` | context | Checks whether an IP matches `C3_IP_ALLOWLIST` (`Config.get(:ip_allowlist)`) | changing the allowlist semantics |

## Processes

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/security/ban_cache.ex` | `C3.Security.BanCache` | genserver | Public, named ETS table of `{ip, until_unix_us}`. It is loaded in `handle_continue(:load)`, and the hourly `:sweep` deletes expired rows | ban lookups are slow or stale, or bans are missing after a restart |
| `lib/c3/security/ban_cache.ex` | `C3.Security.BanCache.put/2` | genserver | When an IP is banned twice, the later `until` wins and an earlier one never overwrites it | changing how overlapping bans for one IP are combined |

Expiry does not depend on the sweep. `lib/c3/security/ban_cache.ex:banned_until` compares against `now` on every read, so the sweep only frees memory.

## Schemas

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/security/join_failure.ex` | `C3.Security.JoinFailure` | schema | One failed join. The `reason` field is `:invalid_secret`, `:unknown_code`, `:session_closed` or `:joins_locked`. When the session is purged, the row survives with `session_id` set to `NULL` | adding a failure reason. Also update the `join_failures_reason_check` DB constraint |
| `lib/c3/security/ip_ban.ex` | `C3.Security.IpBan` | schema | A ban, stored in the `ip_bans` table, which is the source of truth. The `reason` field is `:invalid_secret`, `:unknown_code` or `:admin`; `lifted_at` marks a manual unban | adding a ban reason. Also update `ip_bans_reason_check` |

## Utilities

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/security/cidr.ex` | `C3.Security.CIDR.member?/2` | util | Matches an IPv4 or IPv6 address against CIDR blocks. `::ffff:a.b.c.d` is matched as its IPv4 form. The blocks are re-parsed on every call | changing how IPs are matched for the allowlist or the trusted proxies |
| `lib/c3/security/cidr.ex` | `C3.Security.CIDR.parse!/1` | util | Parses `addr/bits`, or a bare address as a single host. Raises on an invalid block, which is how `lib/c3/config.ex` rejects bad config at boot | accepting new CIDR syntax |
| `lib/c3/security/cidr.ex` | `C3.Security.CIDR.to_string/1` | util | Turns an IP tuple into its canonical string, with mapped addresses unmapped. Bans and failures are keyed by this string | an IP being banned under two different spellings |
| `lib/c3/local_time.ex` | `C3.LocalTime.next_midnight/2` | util | The next local midnight in `C3_TZ`, returned as UTC. A midnight in a DST gap becomes the first instant after the gap; an ambiguous one takes its first occurrence | changing when bans end, or how time zones are handled |
| `lib/c3/local_time.ex` | `C3.LocalTime.day_start/2` | util | The start of the current local day, returned as UTC | changing the day window for the unknown-code count |

## Tests

| Path | Covers |
|---|---|
| `test/c3/security_test.exs` | bans, allowlist, failure counts, unban, history purge |
| `test/c3/security/cidr_test.exs` | parsing and matching CIDR blocks, including IPv4-mapped IPv6 |
| `test/c3/local_time_test.exs` | midnight and day start across time zones and DST edges |
| `test/c3_web/controllers/v1/session_controller_test.exs` | how the join endpoint applies these rules _(only the file name was checked)_ |
| `test/c3/db_constraints_test.exs` | the reason check constraints _(only the file name was checked)_ |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3/sessions.ex` (`unknown_code`, `invalid_secret`, `maybe_lock_joins`, the ban check before create/join) | [`sessions-and-agents`](../sessions-and-agents/02-files.md) |
| `lib/c3_web/plugs/real_ip.ex` (client IP from trusted proxies, uses `CIDR`) | [architecture · request pipeline](../../architecture/01-request-pipeline-and-routing.md) |
| `lib/c3/admin.ex` (`unban`, unlock actions) | [`admin-ui`](../admin-ui/02-files.md) |
| `lib/c3/sweeper.ex` (calls `purge_history`) | [architecture · processes](../../architecture/04-processes-and-background-work.md) |
| `lib/c3/metrics.ex` (`[:ip, :banned]`, `[:join, :failed]`) | [`metrics`](../metrics/00-INDEX.md) |
| `lib/c3/config.ex` (`tz`, `ip_allowlist`, `unknown_code_limit`, `join_lock_ips`) | configuration architecture doc |
