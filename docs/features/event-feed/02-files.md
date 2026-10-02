---
doc: features/event-feed/02-files
repo: c3
kind: feature-files
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Event Feed — files

The feed is two modules and one controller. `lib/c3/events.ex` owns the per-session log, the PubSub fan-out and the long-poll. `lib/c3_web/controllers/v1/event_controller.ex` serves that log over three transports: a JSON long-poll, SSE and the watcher's `text/plain` lines. What surprises people is where events get created. No code in this feature produces them. Every other context calls `lib/c3/events.ex:append!` inside its own transaction. The announcement goes out only because `lib/c3/repo.ex:transaction` wraps each outermost transaction in `lib/c3/events.ex:publish_after`. Anything that writes events without going through `C3.Repo.transaction/2` still commits them, but nobody is woken up.

**Owned globs:** `lib/c3/events.ex`, `lib/c3/events/event.ex`, `lib/c3_web/controllers/v1/event_controller.ex`, `lib/c3_web/controllers/v1/event_json.ex`

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/events.ex` | `append!` | context | takes the next `seq` with an atomic `update_all(inc: [event_seq: 1])` on the session and inserts the event; must run inside the caller's transaction | a new feature needs to record that something happened |
| `lib/c3/events.ex` | `publish_after` | context | holds announcements in the process dictionary (`@pending`) until the outermost transaction returns `{:ok, _}`, and drops them on a rollback or a raise | an event is announced before its commit, or never announced |
| `lib/c3/events.ex` | `wait_after` | context | the long-poll: subscribes *before* it queries `seq > after`, then waits in `await`; also emits `[:c3, :long_poll, :stop]` telemetry, but only when `timeout_ms > 0` | changing long-poll semantics or its metric outcomes (`immediate`/`woken`/`timeout`) |
| `lib/c3/events.ex` | `list_after` | context | an ordered page of events after a cursor, default limit 100, with actor, thread and message preloaded | adding a preload the JSON needs, or changing page size |
| `lib/c3/events.ex` | `list_recent` | context | newest-first page with `seq < before`, for the admin event log | paging the admin log differently |
| `lib/c3/events.ex` | `subscribe` / `unsubscribe` | context | session topic `"session:<id>"`; `unsubscribe` also flushes the `{:c3_events, …}` messages already in the mailbox | a long-lived process listens to one session |
| `lib/c3/events.ex` | `subscribe_admin` / `notify_admin` | context | the `"admin"` topic gets every session's `{:c3_events, …}` plus `{:c3_admin, msg}` notices for changes that leave no event behind | the admin list must react to a change that writes no event |
| `lib/c3/events.ex` | `last_at` | context | timestamp of the last event of a type in a session | asking "when did X last happen" for a session |

## Schemas

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/events/event.ex` | `C3.Events.Event` (`@types`) | schema | `Ecto.Enum` mapping atoms to dotted wire names (`message_posted: "message.posted"`) | adding an event type. Also add a migration, because the DB has an `events_type_check` constraint (see `lib/c3/events/event.ex:changeset`). Earlier types were added that way, e.g. `add_request_cancelled_event`. |
| `lib/c3/events/event.ex` | `changeset` | schema | `seq >= 1`, unique `[:session_id, :seq]`, FKs to session, actor agent, thread and message | changing what an event may reference |

## Controllers

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/controllers/v1/event_controller.ex` | `index` | controller | `GET /v1/sessions/:code/events`: `wait` capped by `long_poll_max_wait`, `limit` clamped to 1..100 | changing JSON long-poll parameters |
| `lib/c3_web/controllers/v1/event_controller.ex` | `watch` / `watch_after` | controller | `GET /v1/sessions/:code/watch`: re-polls with an advanced cursor while the events are irrelevant to the caller (`C3.Watch.line/2` returns nothing), so it answers only on something that concerns the caller or when the deadline passes | the watcher wakes up too often or misses events |
| `lib/c3_web/controllers/v1/event_controller.ex` | `stream` / `deliver` / `listen` | controller | SSE with `retry: 3000`, resume from `Last-Event-ID` (falling back to `?after=`), `x-accel-buffering: no` for buffering proxies; a keepalive reloads the agent and stops if it is no longer `:active` | changing SSE framing, resume or keepalive |
| `lib/c3_web/controllers/v1/event_controller.ex` | `ends_stream?` | controller | closes the stream on `session_closed`, on the caller's own `agent_left` (matched by actor id), or on `agent_revoked` (matched by payload `"name"`, not id) | a new event should end a stream |
| `lib/c3_web/controllers/v1/event_controller.ex` | `heartbeat` | controller | `POST /v1/heartbeat` returns `you` and `last_seen_at` | changing the heartbeat response |
| `lib/c3_web/controllers/v1/event_controller.ex` | `parse_int` | controller | non-negative integers only; anything else is `{:error, {:invalid, …}}` → 422 | accepting a new query parameter |
| `lib/c3_web/controllers/v1/event_json.ex` | `event` / `index` | dto | event wire shape with readable refs (`AG2`, `T3`, `T3.2`) from `C3.Threads`; `last_seq` echoes `after` when the page is empty | adding a field to the event object |
| `lib/c3_web/controllers/v1/event_json.ex` | `type` | dto | atom → dotted name via `Ecto.Enum.mappings`; the SSE `event:` line uses it too | renaming how types appear on the wire |

## Tests

| Path | Covers |
|---|---|
| `test/c3/events_feed_test.exs` | announcement after commit only, none on rollback or raise, nested transactions; the long-poll's gap between subscribe and query, ignoring stale `seq`, no subscription left behind |
| `test/c3/events_test.exs` | dotted type storage, payload default, `seq` required and unique per session, `list_after/3` order and limit |
| `test/c3_web/controllers/v1/event_controller_test.exs` | `/events` long-poll (wait cap, paging, a close while waiting then 410, 422/401), feed counted as presence and not activity, SSE (backlog, `Last-Event-ID`, end on leave/revoke/close, keepalive) |
| `test/c3_web/controllers/v1/watch_test.exs` | the `/watch` text endpoint |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3/watch.ex` | `watcher-and-plugin`. It decides which events concern an agent and formats the `/watch` line. |
| `lib/c3/repo.ex` | the shared data layer: its `transaction` override is what calls `lib/c3/events.ex:publish_after` |
| `lib/c3_web/router.ex` | request pipeline. The `:feed` pipeline uses `AgentAuth, activity: false`. `/events/stream` and `/watch` sit under `:sse`, which has no `accepts`, so `Accept: text/event-stream` and `text/plain` are not answered with 406. |
| `lib/c3/threads.ex`, `lib/c3/sessions.ex`, `lib/c3/sessions/lifecycle.ex` | `threads-and-requests`, `sessions-and-agents`, `session-lifecycle`: these call `append!` |
| `lib/c3_web/mcp/tools.ex` | `mcp-server`: the `c3_events` tool, a poll that does not wait |
| `lib/c3_web/live/admin/session_live.ex` | `admin-ui`: consumes `list_after`/`list_recent` and the admin topic |

## Notes

- `docs/api.md` documents the feed's endpoints and limits (100 events per page). The code agrees, except that `limit` is a query parameter clamped by `lib/c3_web/controllers/v1/event_controller.ex:index`, not fixed.
- If the node dies between a commit and its broadcast, the waiter times out and the next poll with the same `after` returns the event (`lib/c3/events.ex` moduledoc). The table is the truth. Broadcasts only say "there is something up to `seq`".
