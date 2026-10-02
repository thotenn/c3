---
doc: features/event-feed/00-INDEX
repo: c3
kind: feature-index
tier: B
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Event Feed

Every session keeps an ordered log of everything that happened in it: an agent joined, a thread opened, a message was posted, a request was claimed or cancelled, a failed join, the session is about to close. Agents use the log to find out what changed without polling every thread. They can page through it, hold a request open until something new arrives, keep a live stream open, or ask for only the lines that concern them. A client that resumes from the last number it saw never misses an event and never gets one twice.

## Does this ticket belong here?

**Yes if it mentions:** the watcher missing an event, or seeing one twice, after a reconnect; a long-poll that returns too early, too late or empty; the event cursor / `last_seq` / `after`; the SSE stream dropping, buffering behind a proxy, missing keepalives, or not closing after the session ends; the watch output listing events that are someone else's; a new kind of event; gaps in event numbering; the readable refs (`AG2`, `T3`, `T3.2`) inside an event.
**UI labels:** `GET /v1/sessions/{code}/events`, `/events/stream`, `/watch`, `POST /v1/heartbeat`, query params `after`, `wait`, `limit`, header `Last-Event-ID`, response fields `events`, `last_seq`, `seq`, `type`, `actor`, `thread`, `message`, `payload`, the `cursor <seq>` line, the `: keepalive` comment, event types such as `message.posted`, `thread.status_changed`, `session.closing_soon` (full list in `lib/c3/events/event.ex:@types`).
**Routes:** `/v1/sessions/:code/events`, `/v1/sessions/:code/events/stream`, `/v1/sessions/:code/watch`, `/v1/heartbeat`
**No — go elsewhere if:**
- the problem is which lines `/watch` writes for an event, or the watcher script and plugin → [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md) (`lib/c3/watch.ex` owns the line format)
- an event is appended with the wrong payload, or at the wrong moment, by a thread or request action → [`threads-and-requests`](../threads-and-requests/00-INDEX.md)
- the problem is the `c3_events` MCP tool → [`mcp-server`](../mcp-server/00-INDEX.md)
- the problem is the event log page in the admin → [`admin-ui`](../admin-ui/00-INDEX.md)
- the problem is the long-poll duration metric → [`metrics`](../metrics/00-INDEX.md)

## Entry points

| Route | Page component | Module root |
|---|---|---|
| `GET /v1/sessions/:code/events` | `lib/c3_web/controllers/v1/event_controller.ex:index` | `lib/c3/events.ex` |
| `GET /v1/sessions/:code/events/stream` | `lib/c3_web/controllers/v1/event_controller.ex:stream` | `lib/c3/events.ex` |
| `GET /v1/sessions/:code/watch` | `lib/c3_web/controllers/v1/event_controller.ex:watch` | `lib/c3/events.ex` |
| `POST /v1/heartbeat` | `lib/c3_web/controllers/v1/event_controller.ex:heartbeat` | — |

Calls into this feature from code (not routes): `lib/c3/events.ex:append!` (from `lib/c3/sessions.ex`, `lib/c3/threads.ex`, `lib/c3/sessions/lifecycle.ex`), `lib/c3/events.ex:publish_after` (from `lib/c3/repo.ex`), and `lib/c3/events.ex:subscribe_admin` / `lib/c3/events.ex:notify_admin` (from the admin LiveViews).

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md) | Which events concern an agent and how each becomes a `/watch` line (`lib/c3/watch.ex`). This feature only loops on it in `lib/c3_web/controllers/v1/event_controller.ex:watch_after`. |
| [`threads-and-requests`](../threads-and-requests/00-INDEX.md) | When `message.posted`, `request.claimed`, `thread.status_changed` and similar events are appended, and what their payload holds (`lib/c3/threads.ex`) |
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) / [`join-security`](../join-security/00-INDEX.md) / [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | The `agent.*`, `security.*` and `session.*` events and their payloads (`lib/c3/sessions.ex`, `lib/c3/sessions/lifecycle.ex`) |
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) | Agent token auth, and the rule that feed requests do not count as session activity (`lib/c3_web/plugs/agent_auth.ex`) |
| [`mcp-server`](../mcp-server/00-INDEX.md) | The `c3_events` tool, which calls `lib/c3/events.ex:wait_after` with no wait |
| [`admin-ui`](../admin-ui/00-INDEX.md) | Rendering the admin's event log and session list. Here: only `lib/c3/events.ex:list_recent` and the `admin` topic. |
| [`metrics`](../metrics/00-INDEX.md) | Collecting `[:c3, :long_poll, :stop]`. Here: only emitting it in `lib/c3/events.ex:wait_after`. |

## Notes

- **The PubSub message is a hint, not the data.** `{:c3_events, session_id, seq}` carries only the highest `seq` of a transaction, and it is sent after the commit (`lib/c3/events.ex:publish_after`, wired in by `lib/c3/repo.ex`). Every listener queries the table again. Never put event data in the broadcast.
- **`append!` must run inside the caller's transaction.** The `seq` comes from an atomic `update_all(inc: [event_seq: 1])` on the session row (`lib/c3/events.ex:append!`), so the counter and the event commit together, and a rollback leaves no gap. If you call it outside a transaction, it broadcasts right away.
- **Subscribe first, then query.** `lib/c3/events.ex:wait_after` and the SSE path in `lib/c3_web/controllers/v1/event_controller.ex:stream` subscribe before they first call `list_after`, so no event can land in the gap. The `:subscribed` option is a test hook that commits an event inside that gap. If you change either path, keep this order.
- **A lost publish is safe.** If the node dies between the commit and the broadcast, the waiter times out, and the next poll with the same `after` returns the event.
- **`limit` is capped at 100 everywhere.** On `/events` it is clamped to 1–100 (`lib/c3_web/controllers/v1/event_controller.ex:@max_limit`), and `wait` is capped at the `long_poll_max_wait` config. SSE calls `list_after` with its default limit and sends events in batches until it catches up.
- **`/watch` can hold a request even when events arrive.** If none of the new events concern the caller, `watch_after` moves the cursor forward and waits again until the deadline. The `cursor` line can therefore move forward while no event lines come back.
- **When an SSE stream ends is decided in `ends_stream?`:** on `session.closed`, on the caller's own `agent.left` (matched by actor id), or on the caller's own `agent.revoked` (matched by `payload["name"]`, because a revoke's actor is the agent who revoked). Each keepalive reloads the agent and stops the stream if it is no longer `:active`. It also calls `Sessions.touch_seen`, so a keepalive counts as a sign of life.
- **Adding an event type** means adding it to `lib/c3/events/event.ex:@types`. The `events_type_check` constraint in the database also has to accept it (`lib/c3/events/event.ex:changeset`), so a migration is likely needed _(migration not checked)_. The `/watch` mapping in `lib/c3/watch.ex` and the type table in `docs/api.md` also need the new type.
- **The wire type is the dotted string** (`message.posted`), not the atom; it is mapped in `lib/c3_web/controllers/v1/event_json.ex:type`. `last_seq` echoes `after` when the page is empty (`lib/c3_web/controllers/v1/event_json.ex:index`).
- **Telemetry fires only for real long-polls** (`timeout_ms > 0`), with outcome `immediate`, `woken` or `timeout`.

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | how an event travels from `append!` through the commit and PubSub to a waiting long-poll, SSE stream or `/watch` request |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |

## Related

- Architecture: _(undetermined)_
- Features: [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md), [`threads-and-requests`](../threads-and-requests/00-INDEX.md), [`mcp-server`](../mcp-server/00-INDEX.md), [`admin-ui`](../admin-ui/00-INDEX.md), [`metrics`](../metrics/00-INDEX.md)
