---
doc: features/session-lifecycle/02-files
repo: c3
kind: feature-files
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Session Lifecycle — files

All of this feature is in one context module, `lib/c3/sessions/lifecycle.ex`. Nothing calls it on a request path. `lib/c3/sweeper.ex` runs its three passes in order on each tick: `warn_closing`, `close_expired`, `purge`. The admin calls `purge_session` from `lib/c3/admin.ex`. Most people expect the close itself to be here, and it isn't. `lib/c3/sessions/lifecycle.ex:close_expired` only picks the sessions and the reason. The status change, the token revocation and the event come from `lib/c3/sessions.ex:close_session!`. This module passes it a `dynamic` guard, so the idle close re-checks `last_activity_at` inside the `UPDATE`. Without that guard, a request that lands between the scan and the close would not keep the session open.

**Owned globs:** `lib/c3/sessions/lifecycle.ex`

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/sessions/lifecycle.ex` | `close_expired/1` | context | closes open sessions past `session_idle_ttl` (`:idle`) or `expires_at` (`:max_ttl`, wins when both apply), actor `nil` | changing when a session auto-closes, adding a close reason |
| `lib/c3/sessions/lifecycle.ex` | `warn_closing/1` | context | appends `session_closing_soon` events `session_closing_soon` seconds before the earlier of the two closes | changing the warning lead time, payload, or the re-warn rules |
| `lib/c3/sessions/lifecycle.ex` | `warned?/2` (private) | context | dedup: once for `max_ttl`, once per idle stretch (an idle warning older than `last_activity_at` doesn't count) | the warning fires twice or never re-arms |
| `lib/c3/sessions/lifecycle.ex` | `purge/1` | context | deletes closed sessions whose `closed_at` is older than `retention_days` (`0` = first sweep after the close) | changing retention |
| `lib/c3/sessions/lifecycle.ex` | `purge_session/1` | context | deletes one closed session in a transaction; returns `{:error, :not_closed}` or `{:error, :not_found}`; then calls `C3.Attachments.delete_session_files` | admin purge behavior, error cases |
| `lib/c3/sessions/lifecycle.ex` | `delete_session!/1` (private) | context | explicit child-first delete: idempotency keys → attachments → events → messages → threads → agents → session; it nulls `JoinFailure.session_id` instead of deleting the row | **adding any table with a `session_id` or `agent_id` FK** — it must be added here, in order |

Traps:
- `lib/c3/sessions/lifecycle.ex:delete_session!` doesn't trust SQLite's `ON DELETE CASCADE`, because the cross FKs to `agents` make the cascade order unreliable. A new child table that isn't listed here can make the final `{1, _}` match crash.
- Attachment files are removed only after the transaction commits. If the process crashes in between, the files are left orphaned until `lib/c3/attachments.ex:sweep_orphans` cleans them up.
- `lib/c3/sessions/lifecycle.ex:maybe_warn` skips a session whose close time is already past. A session that is overdue gets closed, never warned.
- Every public function takes `now` as an argument. Tests drive time this way, so keep that parameter.

## Processes

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/sweeper.ex` | `C3.Sweeper` | genserver | calls the three passes each tick and reports `sessions_warned` / `sessions_closed` / `sessions_purged` | changing pass order or cadence (owned by background processes) |

## Tests

| Path | Covers |
|---|---|
| `test/c3/sessions/lifecycle_test.exs` | idle warning once, re-armed by new activity; `max_ttl` warning once; no warning when overdue or closed; `close_expired` closes as system and revokes tokens; `max_ttl` precedence; the in-row re-check race; purge deletes everything, never touches open sessions, `retention_days 0`; the sweeper runs every job |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3/sessions.ex:close_session!` | `sessions-and-agents` |
| `lib/c3/sweeper.ex` | architecture — background processes |
| `lib/c3/attachments.ex:delete_session_files`, `lib/c3/attachments.ex:sweep_orphans` | `attachments` |
| `lib/c3/admin.ex` (caller of `purge_session/1`) | `admin-ui` |
| `lib/c3/events.ex` (`Events.append!`) | `event-feed` |
| `lib/c3/security/join_failure.ex` | `join-security` |
| `lib/c3/config.ex` (`session_idle_ttl`, `session_closing_soon`, `retention_days`) | architecture — configuration |
