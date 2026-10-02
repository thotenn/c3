---
doc: features/join-security/02-files
repo: c3
kind: feature-files
anchored_to: e99b2ae
generated: 2026-10-02
---
# Join Security — files

Join security has one context (`lib/c3/security.ex:C3.Security`), two schemas, an ETS GenServer, a CIDR helper and a time-zone helper. It does not decide when a failed join turns into a ban. Those decisions live in `lib/c3/sessions.ex:C3.Sessions`. It records the failure (`Security.record_failure`), compares the counts with the `Config` limits, and calls `Security.ban` and then `Security.cache_ban` after the transaction commits. `C3.Security` only provides the parts those decisions use: counters, ban-length rules and storage. People are also surprised that every row is keyed by a *subject*, not an address (`lib/c3/security/cidr.ex:subject`). An IPv4 address stays as it is. An IPv6 address becomes its `/C3_IPV6_PREFIX` network. The exact address is kept separately in `ip_full`.

**Owned globs:** `lib/c3/security.ex`, `lib/c3/security/*.ex`, `lib/c3/local_time.ex`

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/security.ex` | `C3.Security.secret_ban_until/3` | context | ban length for a wrong secret: next step of `@ban_steps` (60 s, 600 s, 3600 s), capped at local midnight; midnight straight away if the subject was already banned in *another* session today | changing how long wrong-secret bans last, or how they escalate |
| `lib/c3/security.ex` | `C3.Security.ban/5` | context | inserts an `IpBan` for the subject (`until` defaults to next local midnight) and emits `[:ip, :banned]`; returns `nil` for allowlisted IPs. It does **not** update ETS | adding a ban reason; banning from a new code path (remember to call `cache_ban/1` after commit) |
| `lib/c3/security.ex` | `C3.Security.banned_until/2` | context | the hot-path check for `create`/`join`: allowlist first, then `BanCache` only (no DB) | a ban is ignored or wrongly enforced at join |
| `lib/c3/security.ex` | `C3.Security.record_failure/3` | context | inserts a `JoinFailure` (subject in `ip`, address in `ip_full`, `attempted_code` cut to 32 chars) and emits `[:join, :failed]` | logging a new kind of failed join or a new field |
| `lib/c3/security.ex` | `C3.Security.unknown_codes_today/2`, `C3.Security.secret_failures/3`, `C3.Security.invalid_secret_ips/2` | context | the counters behind the thresholds: unknown codes per local day, wrong secrets per subject per session, distinct subjects per session (session join lock) | changing what counts toward a threshold or the time window it counts over |
| `lib/c3/security.ex` | `C3.Security.unban/2` | context | sets `lifted_at` on bans in force and removes the entry from `BanCache`; takes an address or a network and normalizes it with `normalize_subject` | admin unban fails to match a ban (subject form mismatch) |
| `lib/c3/security.ex` | `C3.Security.allowlisted?/1` | context | `C3_IP_ALLOWLIST` check. A network subject must fit *entirely* inside the allowlist (`CIDR.block_member?`) | changing allowlist semantics |
| `lib/c3/security.ex` | `C3.Security.purge_history/1` | context | deletes failures, and bans that ended, older than `@history_days` (30) | changing how long security history is kept |
| `lib/c3/security.ex` | `C3.Security.list_active_bans/1` | context | bans not expired and not lifted; used by `BanCache.load` and the admin | changing what "in force" means |

## Processes

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/security/ban_cache.ex` | `C3.Security.BanCache` | genserver | public ETS mirror of bans in force. Loaded in `handle_continue(:load)`, swept hourly (`@sweep_ms`). `ip_bans` stays the source of truth | ban checks are stale after a restart, or a new node or table is needed |
| `lib/c3/security/ban_cache.ex` | `C3.Security.BanCache.put/2` | genserver | keeps the *later* `until` for an IP, so a shorter ban never shortens a longer one | changing how overlapping bans combine |

## Schemas

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/security/join_failure.ex` | `C3.Security.JoinFailure` | schema | one failed join. `reason` ∈ `invalid_secret · unknown_code · session_closed · joins_locked`. `session_id` becomes `NULL` when the session is purged | adding a failure reason (also needs a migration for the `join_failures_reason_check` constraint) |
| `lib/c3/security/ip_ban.ex` | `C3.Security.IpBan` | schema | one ban. `reason` ∈ `invalid_secret · unknown_code · admin`; `lifted_at` marks an unban | adding a ban reason (needs a migration for the `ip_bans_reason_check` constraint) |

## Utilities

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/security/cidr.ex` | `C3.Security.CIDR.subject/2` | util | address → subject. IPv4-mapped IPv6 collapses to IPv4. Prefix 128 means the bare address. A string that isn't an IP comes back unchanged | changing how IPv6 hosts are grouped |
| `lib/c3/security/cidr.ex` | `C3.Security.CIDR.member?/2`, `C3.Security.CIDR.block_member?/2`, `C3.Security.CIDR.parse/1` | util | CIDR matching, shared with the trusted-proxy and rate-limit plugs | a CIDR parsing bug (it affects proxies and rate limits too) |
| `lib/c3/local_time.ex` | `C3.LocalTime.next_midnight/2`, `C3.LocalTime.day_start/2` | util | local-day boundaries in `C3_TZ`, returned in UTC. A midnight in a DST gap becomes the first instant after the gap; an ambiguous midnight takes its first occurrence | changing how "the day" is defined for bans or counters |

## Tests

| Path | Covers |
|---|---|
| `test/c3/security_test.exs` | the context: bans, failures, counters, unban, purge |
| `test/c3/security/escalation_test.exs` | the `@ban_steps` escalation and the move to a midnight ban across sessions |
| `test/c3/security/cidr_test.exs` | parsing, membership, IPv6 subjects |
| `test/c3/local_time_test.exs` | midnight and day start, including DST edges |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3/sessions.ex` (join thresholds, the session join lock, the ban check at create/join) | [`sessions-and-agents`](../sessions-and-agents/02-files.md) |
| `lib/c3/admin.ex` (`unban`, active-bans listing) | [`admin-ui`](../admin-ui/02-files.md) |
| `lib/c3/sweeper.ex` (calls `purge_history/1`) | [`session-lifecycle`](../session-lifecycle/02-files.md) |
| `lib/c3_web/plugs/real_ip.ex`, `lib/c3_web/plugs/rate_limit.ex` (use `CIDR`) | _(undetermined)_ — request pipeline doc |
| `lib/c3/metrics.ex` (`[:ip, :banned]`, `[:join, :failed]`) | [`metrics`](../metrics/00-INDEX.md) |
| `lib/c3/config.ex` (`:ip_allowlist`, `:ipv6_prefix`, `:tz`, `:unknown_code_limit`) | configuration doc |

## Notes

- `ban/5` and `cache_ban/1` are split on purpose. ETS must be written only after the DB transaction commits, so an `IpBan` that was rolled back never blocks anyone. A new caller that skips `cache_ban/1` creates a ban that is stored but not enforced until the next restart (`BanCache.load`).
- A ban blocks only `create` and `join`. An agent already in a session keeps working with its token from a banned IP (`lib/c3/security.ex:C3.Security` moduledoc).
- The hourly sweep only removes expired ETS entries. A lifted ban leaves ETS only through `unban/2` calling `BanCache.delete`.
