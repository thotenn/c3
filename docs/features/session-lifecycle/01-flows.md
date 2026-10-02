---
doc: features/session-lifecycle/01-flows
repo: c3
kind: feature-flows
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Session Lifecycle — flows

This feature has four flows. Three run automatically. `C3.Sweeper` runs them in this order on every sweep: warn, close, purge. The fourth is the same purge, run on demand by the admin. Only one of them talks to agents: the `session.closing_soon` warning. The close goes through the shared `close_session!`. The purges delete rows and files and emit nothing.

## Flow: agents are warned that the session is about to close

**Entry:** a sweep tick · `lib/c3/sweeper.ex:run`

1. **Trigger** — the sweeper calls the warn step with its own `now`. Every step of one tick shares that `now` · `lib/c3/sweeper.ex:run` → `lib/c3/sessions/lifecycle.ex:warn_closing`
2. **Guard** — the query selects open sessions whose idle close is less than `session_closing_soon` seconds away, or whose `expires_at` is · `lib/c3/sessions/lifecycle.ex:warn_closing`
3. **Logic** — it decides which close comes first. `max_ttl` is chosen when `expires_at` is at or before the idle close; ties go to `max_ttl`. If that close is already in the past, no warning is sent, because the close step handles it · `lib/c3/sessions/lifecycle.ex:maybe_warn`
4. **Guard (dedupe)** — no state column records that a warning went out. The function reads the session's earlier `session_closing_soon` events back from the event log instead. A `max_ttl` warning is sent once per session. An `idle` warning counts as sent only if it is at or after `last_activity_at`, so new activity re-arms it · `lib/c3/sessions/lifecycle.ex:warned?`
5. **Persist / Notify** — it appends a `session_closing_soon` event with payload `reason` and `closes_at`, inside a transaction · `lib/c3/sessions/lifecycle.ex:maybe_warn` (event append owned by `event-feed`)
6. **Respond** — it returns the number of warnings sent, for the sweeper's report · `lib/c3/sessions/lifecycle.ex:warn_closing`

**Touch this flow when:** the warning arrives too often or not at all, the payload needs a new field, or a new close reason needs its own warning.
**Breaks when:** something rewrites or prunes `session_closing_soon` events. The dedupe *is* the event log, so the warning would fire again on every tick. The deduplication also loads every warning the session has received on each tick. That is cheap only while the number of warnings per session stays small.

## Flow: an idle or expired session closes on its own

**Entry:** a sweep tick · `lib/c3/sweeper.ex:run`

1. **Trigger** · `lib/c3/sessions/lifecycle.ex:close_expired`
2. **Guard** — the scan selects open sessions with `last_activity_at <= now - session_idle_ttl` or `expires_at <= now` · `lib/c3/sessions/lifecycle.ex:close_expired`
3. **Logic** — `max_ttl` wins whenever `expires_at` has passed. Otherwise the reason is `idle`, and the close carries an extra `dynamic` condition that re-checks `last_activity_at`. Activity that lands between the scan and the `UPDATE` therefore keeps the session open · `lib/c3/sessions/lifecycle.ex:close_expired`
4. **Persist** — `close_session!` is called with actor `nil`, which records `closed_by: "system"`. It runs a conditional `update_all` and rolls back with `:session_closed` when no row matched · `lib/c3/sessions.ex:close_session!` (owned by `sessions-and-agents`)
5. **Notify** — the close's own events and the `[:session, :closed]` metric come from `close_session!`, not from this module · `lib/c3/sessions.ex:close_session!`
6. **Respond** — it counts only the transactions that returned `{:ok, _}`. A race that was lost is a silent rollback, not an error · `lib/c3/sessions/lifecycle.ex:close_expired`

**Touch this flow when:** you add a close reason, change TTL semantics, or a session closes while it is in use.
**Breaks when:** a code path changes data in a session without bumping `last_activity_at`. That path's activity does not count against the idle TTL, and the re-check does not protect it either.

## Flow: closed sessions are purged after the retention period

**Entry:** a sweep tick · `lib/c3/sweeper.ex:run`

1. **Trigger** · `lib/c3/sessions/lifecycle.ex:purge`
2. **Guard** — it selects closed sessions with `closed_at <= now - retention_days * 86_400`. With `retention_days` set to `0`, a session is purged by the first sweep after it closes · `lib/c3/sessions/lifecycle.ex:purge`
3. **Logic** — each session is purged in its own transaction, through the admin flow below · `lib/c3/sessions/lifecycle.ex:purge_session`
4. **Respond** — it counts the successful purges · `lib/c3/sessions/lifecycle.ex:purge`

**Touch this flow when:** retention rules change, for example per-session retention or keeping an audit trail after a purge.
**Breaks when:** a closed session never gets `closed_at` set. The query can never select it, so it is never purged.

## Flow: the admin purges a closed session now

**Entry:** admin purge action · `lib/c3/admin.ex:purge_session`

1. **Trigger** — the admin layer calls into this module · `lib/c3/admin.ex:purge_session` → `lib/c3/sessions/lifecycle.ex:purge_session`
2. **Guard** — the session is re-read inside the transaction. An open session rolls back `:not_closed`; a missing one rolls back `:not_found` · `lib/c3/sessions/lifecycle.ex:purge_session`
3. **Persist** — rows are deleted children first, by hand, in this order: idempotency keys of the session's agents, attachments, events, messages, threads, agents. Then `JoinFailure.session_id` is set to `nil`, so join-failure rows survive. Finally the session itself is deleted, and the code asserts `{1, _}`. ON DELETE CASCADE exists only as a safety net, because SQLite's cascade order across the cross foreign keys to `agents` is not trusted · `lib/c3/sessions/lifecycle.ex:delete_session!`
4. **Call** — the attachment files are deleted only after the transaction commits. A crash between commit and file deletion leaves orphan files, which a later orphan sweep removes · `lib/c3/sessions/lifecycle.ex:purge_session` (files owned by `attachments`)
5. **Respond** — it returns the transaction result, or `{:error, :not_closed | :not_found}` · `lib/c3/sessions/lifecycle.ex:purge_session`

**Touch this flow when:** you add a table that references `sessions` or `agents`. It must get its own `delete_all` in `lib/c3/sessions/lifecycle.ex:delete_session!`, placed before its parent.
**Breaks when:** a new child table is left out of `delete_session!`. Either the foreign key fails the purge, or the cascade order deletes rows in an order nobody chose. Nothing is broadcast on purge, so a connected client is not told; _(undetermined)_ how it reacts.

## Shared state

- **Session status and close columns.** `status`, `closed_at`, `closed_by`, `close_reason` and `last_activity_at` belong to `sessions-and-agents`, and are written through `lib/c3/sessions.ex:close_session!`.
- **The event log.** It is the write target for the warning, and it is also the warning's dedupe memory. Owned by `event-feed`, which also owns `lib/c3/events.ex`.
- **Config keys.** `session_closing_soon`, `session_idle_ttl` and `retention_days` are read through `C3.Config` (`lib/c3/config.ex`).
- **Files on disk.** Attachment files belong to `attachments`.
- **Join-failure rows.** Owned by `join-security`. A purge detaches these rows instead of deleting them.
