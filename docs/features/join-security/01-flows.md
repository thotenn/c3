---
doc: features/join-security/01-flows
repo: c3
kind: feature-flows
anchored_to: e99b2ae
generated: 2026-10-02
---
# Join Security — flows

This feature has six flows. Two are checks that run on every `create`/`join`: the ban gate, and a join to a session that is closed or locked. Three are failure paths that write history and may ban: an unknown code, a wrong secret, and the session join lock that wrong secrets trigger. The last group lifts a ban or a lock, purges old history, and mirrors bans into ETS. Every count and ban is keyed by a *subject*, not by a raw IP: an IPv4 address, or the IPv6 network of `C3_IPV6_PREFIX` (`lib/c3/security/cidr.ex:subject`). The caller side (`join_session`, `create_session`) belongs to [`sessions-and-agents`](../sessions-and-agents/01-flows.md). It is cited here only where it decides security behaviour.

## Flow: a banned IP tries to create or join

**Entry:** `create_session` / `join_session` (REST and MCP)

1. **Trigger** — the caller creates or joins a session · `lib/c3/sessions.ex:create_session`, `lib/c3/sessions.ex:join_session`
2. **Guard** — `check_ban` runs first, before the code or the secret is looked at · `lib/c3/sessions.ex:check_ban`
3. **Logic** — an allowlisted IP is never banned. A subject network is allowlisted only when the whole network falls inside an allowlist block · `lib/c3/security.ex:allowlisted?`, `lib/c3/security/cidr.ex:block_member?`
4. **Persist / call** — the lookup reads ETS only, keyed by the subject. It never touches the database · `lib/c3/security.ex:banned_until`, `lib/c3/security/ban_cache.ex:banned_until`
5. **Respond / render** — `{:error, :ip_banned, until}` becomes HTTP 403 `ip_banned` with `banned_until`. Nothing is recorded · `lib/c3_web/controllers/v1/fallback_controller.ex:call`

**Touch this flow when:** a ban should also block another action, or allowlist matching has to change.
**Breaks when:** `BanCache` is not running or has not loaded: `:ets.lookup` on the missing table raises. A ban written without `cache_ban/1` is not enforced until the next restart. A ban never blocks an agent that already has a token: token auth does not go through this gate.

## Flow: join to a closed or locked session

**Entry:** `join_session` with a valid code

1. **Trigger** — the code resolves to a session · `lib/c3/sessions.ex:join_session`
2. **Guard** — `status: :closed` or a set `joins_locked_at` matches before the secret is verified · `lib/c3/sessions.ex:join_existing`
3. **Persist / call** — the failure is recorded as `:session_closed` / `:joins_locked`. Neither reason ever bans · `lib/c3/security.ex:record_failure`
4. **Respond / render** — `{:error, :joins_locked}` becomes HTTP 423 · `lib/c3_web/controllers/v1/fallback_controller.ex:call`

**Touch this flow when:** what a locked session reveals has to change.
**Breaks when:** the secret is checked before the lock. A locked session must not leak whether the secret was right (`lib/c3/sessions.ex:join_session` doc).

## Flow: someone tries a code that does not exist

**Entry:** `join_session` with an unknown or malformed code

1. **Trigger** — `Credentials.normalize_code` fails or no session matches · `lib/c3/sessions.ex:join_session`
2. **Logic** — `Credentials.dummy_verify()` burns the same time as a real secret check, so timing does not reveal whether the code exists · `lib/c3/sessions.ex:unknown_code`
3. **Persist / call** — in one transaction it records the `:unknown_code` failure with `session_id` nil and `attempted_code` cut to 32 chars, then counts the subject's unknown codes since local midnight · `lib/c3/security.ex:record_failure`, `lib/c3/security.ex:unknown_codes_today`, `lib/c3/local_time.ex:day_start`
4. **Persist / call** — at `C3_UNKNOWN_CODE_LIMIT` or more (`>=`), it bans until the next local midnight at once, with no steps · `lib/c3/security.ex:ban`, `lib/c3/local_time.ex:next_midnight`
5. **Notify** — `[:c3, :join, :failed]` and `[:c3, :ip, :banned]` telemetry. After the commit, the ban goes into ETS · `lib/c3/security.ex:cache_ban`
6. **Respond / render** — `{:error, :not_found}`

**Touch this flow when:** the daily threshold or the scanning defence changes.
**Breaks when:** `C3_TZ` is wrong: the "day" then resets at the wrong hour. The comparison here is `>=`, while the wrong-secret path uses `>`. Keep that asymmetry in mind when you tune a limit.

## Flow: someone sends a wrong secret

**Entry:** `join_session` with a known code and a bad `secret`

1. **Trigger** — `Credentials.verify_secret` fails · `lib/c3/sessions.ex:join_existing`
2. **Persist / call** — records `:invalid_secret`, then takes `since` = the latest `session_joins_unlocked` / `session_secret_rotated` event, so older failures stop counting · `lib/c3/sessions.ex:invalid_secret`, `lib/c3/sessions.ex:last_reset_at`
3. **Logic** — the subject is banned only once its failures in this session since `since`, the current one included, are more than (`>`) `C3_SECRET_TOLERANCE` · `lib/c3/security.ex:secret_failures`
4. **Logic** — the length comes from the subject's `invalid_secret` bans that day: 1 min, 10 min, then 1 h (`@ban_steps`), capped at local midnight. If the subject was banned for a *different* session code that day, the ban runs straight to midnight · `lib/c3/security.ex:secret_ban_until`
5. **Notify** — a `security_join_failed` event goes to the session, with `ip`, `subject` and `banned_until`. Then the lock check runs (next flow). After the commit, `cache_ban` · `lib/c3/sessions.ex:invalid_secret`
6. **Respond / render** — `{:error, :invalid_secret}`

**Touch this flow when:** the escalation, the tolerance or the alert payload changes.
**Breaks when:** the escalation counts by `session_code`. A ban with a nil `session_code` (an unknown-code or admin ban) is not `:invalid_secret`, so it never counts. `last_reset_at` resets the tolerance count, but not the day's ban steps.

## Flow: too many distinct IPs lock a session's joins

**Entry:** a side effect of a wrong secret

1. **Logic** — it counts the distinct subjects that sent a wrong secret to the session since the last reset · `lib/c3/security.ex:invalid_secret_ips`
2. **Guard** — the lock fires at `C3_JOIN_LOCK_IPS` or more · `lib/c3/sessions.ex:maybe_lock_joins`
3. **Persist / call** — a conditional `update_all` sets `joins_locked_at` only where it is nil · `lib/c3/sessions.ex:maybe_lock_joins`
4. **Notify** — a `session_joins_locked` event with `distinct_ips`, emitted only by the call that won the lock · `lib/c3/sessions.ex:maybe_lock_joins`
5. **Lift** — an agent's `unlock` or the admin, or a secret rotation, clears the lock and starts a new counting window · `lib/c3/sessions.ex:unlock_joins`

**Touch this flow when:** the lock threshold changes, or how a lock is lifted.
**Breaks when:** the reset events are missing. Without `last_reset_at`, the next wrong secret would lock the session again at once.

## Flow: admin unbans an IP

**Entry:** the admin UI unban action · `lib/c3/admin.ex:unban`

1. **Logic** — the input is normalised to the canonical subject: a bare address becomes its subject, an IPv6 `addr/bits` becomes its canonical network form. Anything unparsable is kept as typed · `lib/c3/security.ex:normalize_subject`
2. **Persist / call** — sets `lifted_at` on every ban in force for that subject · `lib/c3/security.ex:unban`
3. **Notify** — the subject is removed from ETS (`lib/c3/security/ban_cache.ex:delete`), and the admin is notified with `{:unbanned, ip}`
4. **Respond / render** — the count of bans lifted. `0` is not an error: the ban may have just expired.

**Touch this flow when:** the admin needs to unban by another key.
**Breaks when:** the admin types an IPv6 network with a prefix other than `C3_IPV6_PREFIX`. It normalises to a subject that no ban row has, so nothing is lifted.

## Flow: ban mirror and history purge (background)

**Entry:** application boot, the hourly sweep, `C3.Sweeper`

1. **Trigger** — `BanCache` starts under the application supervisor and loads the active bans in `handle_continue` · `lib/c3/security/ban_cache.ex:load`, `lib/c3/security.ex:list_active_bans`
2. **Logic** — `put` keeps the later `until` when one subject has several bans. Because of this, an unban has to `delete`, not overwrite · `lib/c3/security/ban_cache.ex:put`
3. **Persist / call** — every hour, the sweep drops expired entries from ETS · `lib/c3/security/ban_cache.ex:handle_info`
4. **Persist / call** — the sweeper deletes join failures, and bans that expired or were lifted, older than 30 days · `lib/c3/security.ex:purge_history`, `lib/c3/sweeper.ex`

**Touch this flow when:** retention changes, or the bans must be shared across nodes. ETS is local to each node, so it is not shared.
**Breaks when:** you run more than one node. Each node only has the bans that it wrote itself, plus the ones loaded at boot.

## Shared state

- `sessions.joins_locked_at` and the `security_join_failed` / `session_joins_locked` / `session_joins_unlocked` / `session_secret_rotated` events belong to [`sessions-and-agents`](../sessions-and-agents/01-flows.md) and [`event-feed`](../event-feed/01-flows.md).
- `join_failures.session_id` is set to NULL when a session is purged (`lib/c3/sessions/lifecycle.ex`). That flow belongs to [`session-lifecycle`](../session-lifecycle/01-flows.md).
- `CIDR.subject/1` is also the key the rate limiter and the real-IP plug use (`lib/c3_web/plugs/rate_limit.ex`, `lib/c3_web/plugs/real_ip.ex`).
- Configuration (`C3_TZ`, `C3_IPV6_PREFIX`, `C3_IP_ALLOWLIST`, `C3_SECRET_TOLERANCE`, `C3_UNKNOWN_CODE_LIMIT`, `C3_JOIN_LOCK_IPS`) lives in `lib/c3/config.ex`. The counters belong to [`metrics`](../metrics/00-INDEX.md). The ban list and the unban action belong to [`admin-ui`](../admin-ui/01-flows.md).
