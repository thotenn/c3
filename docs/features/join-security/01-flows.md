---
doc: features/join-security/01-flows
repo: c3
kind: feature-flows
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Join Security — flows

This feature has five flows. Two run on every `create`/`join`: the ban check that comes before any other work, and the failure recording that can produce a ban after a bad attempt. A third, the join lock, is triggered by wrong secrets but changes the session, not the IP. The last two are maintenance: an admin unban, and the boot load plus sweeps that keep the ETS mirror and the history tables small. The join itself (code normalization, secret verification, adding the agent) belongs to [`sessions-and-agents`](../sessions-and-agents/01-flows.md). This feature owns what happens around it.

## Flow: a banned IP tries to create or join

**Entry:** `create` / `join` (HTTP or MCP tool)

1. **Trigger** — the caller tries to join a session; its IP was already resolved upstream · `lib/c3/sessions.ex:join_session`
2. **Guard** — the ban check runs first, before label validation and before any database read · `lib/c3/sessions.ex:check_ban`
3. **Logic** — an allowlisted IP is never banned, even if an `ip_bans` row exists for it; otherwise the answer comes from ETS only · `lib/c3/security.ex:banned_until`, `lib/c3/security.ex:allowlisted?`, `lib/c3/security/cidr.ex:member?`
4. **Persist / call** — none. A banned attempt is **not** recorded as a `JoinFailure`, so it does not push the IP further toward any threshold · `lib/c3/security/ban_cache.ex:banned_until`
5. **Respond / render** — `{:error, :ip_banned, until}`; `until` is the next local midnight · `lib/c3/sessions.ex:check_ban`

**Touch this flow when:** a ticket asks to change who counts as banned, add an allowlist rule, or show the ban expiry to the client.
**Breaks when:** `BanCache` is not running: the ETS table `C3.Security.BanCache` does not exist and every lookup raises (`lib/c3/application.ex` starts it). A ban that was written but never passed to `cache_ban/1` is invisible to this check. An IPv4-mapped IPv6 client (`::ffff:a.b.c.d`) is matched against the allowlist as IPv4 (`lib/c3/security/cidr.ex:parse_ip`), but the ban key is whatever string the caller passed in. Only `banned_until` (ETS) is consulted, so a ban with a different IP spelling than the lookup is missed.

## Flow: a failed join gets recorded, and may ban the IP

**Entry:** `join` with an unknown code, a wrong secret, a closed session, or a locked session

1. **Trigger** — the session lookup or secret check fails · `lib/c3/sessions.ex:join_existing`, `lib/c3/sessions.ex:unknown_code`, `lib/c3/sessions.ex:invalid_secret`
2. **Logic** — the reason decides the outcome:
   - `:session_closed` and `:joins_locked` are recorded and never ban.
   - `:invalid_secret` bans on the **first** wrong attempt.
   - `:unknown_code` bans only once the IP's count for the local day reaches `unknown_code_limit`.

   A locked session does not check the secret at all, so the response does not reveal whether the secret was right · `lib/c3/sessions.ex:join_existing`, `lib/c3/security.ex:unknown_codes_today`
3. **Persist / call** — a `join_failures` row is written. `attempted_code` is cut to 32 characters, and `session_id` is `nil` for an unknown code. The ban (`ip_bans`, until `LocalTime.next_midnight/2`) is written in the same transaction. An unknown code also runs `Credentials.dummy_verify()` so its timing matches a real secret check · `lib/c3/security.ex:record_failure`, `lib/c3/security.ex:ban`, `lib/c3/local_time.ex:next_midnight`
4. **Notify** — `[:join, :failed]` and `[:ip, :banned]` metrics are emitted. A wrong secret also appends `security_join_failed` to the session's event feed (see [`event-feed`](../event-feed/01-flows.md)) · `lib/c3/security.ex:record_failure`, `lib/c3/sessions.ex:invalid_secret`
5. **Persist / call** — **after** the transaction commits, the ban is mirrored into ETS. A later `until` wins over an earlier one for the same IP · `lib/c3/security.ex:cache_ban`, `lib/c3/security/ban_cache.ex:put`
6. **Respond / render** — `{:error, :not_found}` / `:invalid_secret` / `:session_closed` / `:joins_locked` · `lib/c3/sessions.ex:join_session`

**Touch this flow when:** changing a threshold or a ban duration, adding a failure reason (it must be added to the `Ecto.Enum` in `lib/c3/security/join_failure.ex:JoinFailure` **and** to the `join_failures_reason_check` DB constraint), or changing what a failed join leaks.
**Breaks when:**
- `cache_ban/1` is called inside the transaction. A rollback would leave a ban in ETS with no row behind it.
- The `ban/4` call is forgotten after a new failure path. The DB row exists but ETS never learns about it until the next boot.
- `ban/4` returns `nil` for allowlisted IPs, and `cache_ban(nil)` is a no-op. Callers must not pattern-match on a struct.
- `C3_TZ` is not a valid zone. `DateTime.shift_zone!` raises in `lib/c3/local_time.ex:next_midnight` and in `lib/c3/local_time.ex:day_start`.

## Flow: enough distinct IPs lock a session's joins

**Entry:** a wrong secret (the step above), inside the same transaction

1. **Trigger** — after recording `:invalid_secret` · `lib/c3/sessions.ex:invalid_secret`
2. **Logic** — counts the distinct IPs that sent a wrong secret since the latest `session_joins_unlocked` or `session_secret_rotated` event (or ever, if neither exists). Without that cutoff, the next failure after an unlock would relock the session immediately · `lib/c3/sessions.ex:maybe_lock_joins`, `lib/c3/security.ex:invalid_secret_ips`
3. **Guard** — the lock applies only when the count is at least `join_lock_ips` · `lib/c3/sessions.ex:maybe_lock_joins`
4. **Persist / call** — sets `joins_locked_at`, but only where it is still `nil` (a race-safe single update) · `lib/c3/sessions.ex:maybe_lock_joins`
5. **Notify** — `session_joins_locked` is appended only if this update actually locked the session · `lib/c3/sessions.ex:maybe_lock_joins`

**Touch this flow when:** changing the lock threshold, or adding another action that should reset the count (that action must emit an event, and the event must be added to the list in `maybe_lock_joins`).
**Breaks when:** rows of `join_failures` are deleted early. `purge_history/1` drops rows after 30 days, so a session open longer than that "forgets" old offenders. Unlocking and rotating the secret belong to [`session-lifecycle`](../session-lifecycle/01-flows.md).

## Flow: an admin lifts a ban

**Entry:** admin UI unban action

1. **Trigger** — `lib/c3/admin.ex:unban`
2. **Persist / call** — sets `lifted_at` on every ban of the IP that is still in force. The row stays as history · `lib/c3/security.ex:unban`
3. **Notify** — the IP is removed from ETS so `create`/`join` work again at once, and admin LiveViews get `{:unbanned, ip}` · `lib/c3/security/ban_cache.ex:delete`, `lib/c3/admin.ex:unban`
4. **Respond / render** — the count of bans lifted. `0` is not an error, because the ban may have just expired · `lib/c3/security.ex:unban`

**Touch this flow when:** adding unban to another surface, or adding per-ban (rather than per-IP) lifting.
**Breaks when:** the IP string differs from the stored one (for example, a different IPv6 spelling). Matching is exact string equality in both the query and ETS.

## Flow: boot load, hourly sweep and history purge

**Entry:** application start; timers

1. **Trigger** — `BanCache` starts under the supervisor and loads every active ban in `handle_continue` · `lib/c3/security/ban_cache.ex:load`, `lib/c3/security.ex:list_active_bans`
2. **Logic** — every hour, the ETS sweep drops entries whose `until` has passed. Lookups already ignore expired entries, so the sweep only frees memory · `lib/c3/security/ban_cache.ex:handle_info`
3. **Persist / call** — the global sweeper deletes `join_failures` and ended bans older than 30 days · `lib/c3/sweeper.ex:run`, `lib/c3/security.ex:purge_history`

**Touch this flow when:** changing retention, or adding a second node. ETS is per-node, and there is no cross-node invalidation of `BanCache`.
**Breaks when:** the database is unreachable at boot. `load/0` runs inside the GenServer and a crash there takes `BanCache` down with it.

## Shared state

- **Client IP**: resolved by `lib/c3_web/plugs/real_ip.ex:client_ip` using trusted proxies parsed with `lib/c3/security/cidr.ex:parse!`. Owned by the request pipeline.
- **Config**: `tz`, `ip_allowlist`, `unknown_code_limit`, `join_lock_ips`, read via `lib/c3/config.ex`. Owned by configuration.
- **`sessions.joins_locked_at`** and the `session_joins_unlocked` / `session_secret_rotated` events: owned by [`sessions-and-agents`](../sessions-and-agents/01-flows.md) and [`session-lifecycle`](../session-lifecycle/01-flows.md).
- **`security_join_failed` events**: these go to the session feed of [`event-feed`](../event-feed/01-flows.md).
- **Metrics**: `[:join, :failed]` and `[:ip, :banned]`, owned by [`metrics`](../metrics/00-INDEX.md).
