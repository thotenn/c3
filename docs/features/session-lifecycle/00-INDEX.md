---
doc: features/session-lifecycle/00-INDEX
repo: c3
kind: feature-index
tier: B
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Session Lifecycle

This feature ends sessions automatically. If agents stop talking for too long, or a session reaches its maximum lifetime, it closes. Before either close happens, the agents get one advance warning. After the retention period, a closed session and everything in it are deleted for good: threads, messages, events, agents and attachment files. An operator can also delete a closed session right away from the admin UI.

## Does this ticket belong here?

**Yes if it mentions:** a session closing on its own, a session timing out or expiring while idle, a "closing soon" warning that comes twice, never comes or comes too late, an idle session that stays open, activity that should keep a session alive, the reason a session closed (idle vs. max lifetime), retention, old sessions still in the database or old attachment files still on disk, a purge that fails or leaves rows behind, a foreign-key error while deleting a session.
**UI labels:** `session.closing_soon` (event type), `close_reason` values `idle` / `max_ttl`, config keys `session_idle_ttl`, `session_closing_soon`, `retention_days`, the admin's purge action.
**Routes:** none of its own. It runs from `lib/c3/sweeper.ex` (`sessions_warned`, `sessions_closed`, `sessions_purged`), and the admin reaches it through `lib/c3/admin.ex:purge_session`.
**No — go elsewhere if:** a person or agent closes the session by hand, or the ticket is about what closing does to agents and tokens → [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md). The watcher misses the closing-soon or closed event → [`event-feed`](../event-feed/00-INDEX.md) / [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md). The purge button or its page → [`admin-ui`](../admin-ui/00-INDEX.md). Orphan attachment files not tied to a purge → [`attachments`](../attachments/00-INDEX.md).

## Entry points

| Route | Page component | Module root |
|---|---|---|
| — (sweeper tick) | `lib/c3/sweeper.ex` calls `lib/c3/sessions/lifecycle.ex:warn_closing`, `lib/c3/sessions/lifecycle.ex:close_expired`, `lib/c3/sessions/lifecycle.ex:purge` | `lib/c3/sessions/lifecycle.ex` |
| — (admin action) | `lib/c3/admin.ex:purge_session` → `lib/c3/sessions/lifecycle.ex:purge_session` | `lib/c3/sessions/lifecycle.ex` |

## Traps

- **The warning reason is chosen by whichever close comes first.** `lib/c3/sessions/lifecycle.ex:maybe_warn` picks `"idle"` only when `expires_at` is strictly later than the idle deadline; otherwise it picks `"max_ttl"`. The candidate query in `lib/c3/sessions/lifecycle.ex:warn_closing` uses `<=` on both deadlines, so a session can match on either one.
- **"Warn once" is computed from past events.** There is no flag column. `lib/c3/sessions/lifecycle.ex:warned?` scans the session's `session_closing_soon` events. An `idle` warning counts only if it was emitted at or after `last_activity_at`, so new activity re-arms it. A `max_ttl` warning counts forever. Any change to how activity bumps `last_activity_at` changes when warnings fire again.
- **No warning for a close that is already due.** `lib/c3/sessions/lifecycle.ex:maybe_warn` skips the warning when `closes_at` is not in the future. If the sweeper falls behind, the session closes without a warning.
- **`max_ttl` wins when both apply.** In `lib/c3/sessions/lifecycle.ex:close_expired`, the reason is `:idle` only when `expires_at` is still in the future.
- **The idle close is race-safe; the max-TTL close is not conditional.** For `:idle`, `close_expired` passes `dynamic([s], s.last_activity_at <= ^idle_cutoff)` as the `still` guard to `Sessions.close_session!`. That guard re-checks activity inside the `UPDATE`, so a request that lands between the scan and the close keeps the session open. `:max_ttl` passes `dynamic(true)`. The close itself (`close_session!`) belongs to [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md).
- **`retention_days = 0` means "at the next sweep"**, not "never". The cutoff in `lib/c3/sessions/lifecycle.ex:purge` is `closed_at <= now`.
- **Delete order is manual, on purpose.** `lib/c3/sessions/lifecycle.ex:delete_session!` deletes children by hand, in this order: idempotency keys (through the session's agents) → attachments → events → messages → threads → agents → session. SQLite's cascade order with the cross foreign keys to `agents` is not reliable, so `ON DELETE CASCADE` is only a safety net. A new table that references a session or an agent must be added to this list.
- **Join failures survive the purge.** `JoinFailure` rows are nulled (`set: [session_id: nil]`), not deleted. They keep counting for [`join-security`](../join-security/00-INDEX.md).
- **Files are deleted after the commit.** `lib/c3/sessions/lifecycle.ex:purge_session` calls `Attachments.delete_session_files` only once the transaction has succeeded. If the process crashes in between, the files are left for `Attachments.sweep_orphans/1`.
- **`purge_session` refuses open sessions.** It returns `{:error, :not_closed}` for an open session and `{:error, :not_found}` for a missing one. The admin UI relies on these exact atoms.

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) | `Sessions.close_session!`: what a close writes, the `session.closed` event, token revocation, manual close |
| [`event-feed`](../event-feed/00-INDEX.md) | `Events.append!` and how `session.closing_soon` reaches watchers |
| [`attachments`](../attachments/00-INDEX.md) | `Attachments.delete_session_files`, `Attachments.sweep_orphans/1`, file storage |
| [`admin-ui`](../admin-ui/00-INDEX.md) | the purge button, confirmation, LiveView refresh |
| [`join-security`](../join-security/00-INDEX.md) | `JoinFailure` rows and lockouts |
| [`metrics`](../metrics/00-INDEX.md) | reporting the sweeper counts |

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | how a sweeper tick moves a session from warning to close to purge |
| [`02-files.md`](02-files.md) | which function in `lib/c3/sessions/lifecycle.ex` to touch |

## Related

- Architecture: background processes (the sweeper), configuration (`session_idle_ttl`, `session_closing_soon`, `retention_days`), data model (foreign keys and cascades) — _(undetermined: document paths)_
- Features: [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md), [`event-feed`](../event-feed/00-INDEX.md), [`attachments`](../attachments/00-INDEX.md), [`admin-ui`](../admin-ui/00-INDEX.md)
