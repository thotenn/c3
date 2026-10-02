---
doc: features/event-feed/01-flows
repo: c3
kind: feature-flows
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Event Feed — flows

The feed has one write flow and four read flows. In the write flow, any domain change appends an event and announces it after the commit. The four read flows are the JSON long-poll, the SSE stream, the watcher's `text/plain` long-poll and the heartbeat. They differ in format and in how they wait. All three waiting flows follow the same rule: subscribe first, then query the table. The PubSub message only says that something exists up to a `seq`. The `events` table holds the actual events.

## Flow: a domain action records an event

**Entry:** any context function that changes session state (join, post, claim, close…)

1. **Trigger** — a context such as threads or sessions calls `append!` inside its transaction · `lib/c3/events.ex:append!`
2. **Logic** — gets the next `seq` with an atomic `update_all(inc: [event_seq: 1])` on the session row. Because of this, `seq` per session has no gaps and must stay in the caller's transaction · `lib/c3/events.ex:append!`
3. **Persist** — inserts the event. The changeset requires `seq >= 1`, `[:session_id, :seq]` must be unique, and `type` must be one of the dotted `@types` · `lib/c3/events/event.ex:changeset`
4. **Notify (deferred)** — inside a transaction, `notify` stores only the highest `seq` for each session in the process dictionary (`@pending`) · `lib/c3/events.ex:notify`
5. **Notify (commit)** — `publish_after` broadcasts `{:c3_events, session_id, seq}` to `session:<id>` and to `admin`, but only if the transaction returned `{:ok, _}`. On a rollback or a raise, nothing is sent · `lib/c3/events.ex:publish_after`, wired by `C3.Repo.transaction/2` in `lib/c3/repo.ex`
6. **Respond** — returns the inserted `%Event{}` to the caller · `lib/c3/events.ex:append!`

**Touch this flow when:** adding a new event type. Add it to `@types` in `lib/c3/events/event.ex`. The `events_type_check` DB constraint also has to accept it, which takes a migration. Then decide whether `C3.Watch.line` (`lib/c3/watch.ex:line`) should produce a line for it.
**Breaks when:** `append!` is called outside a transaction. Then the counter increment and the insert do not commit together, and the broadcast goes out immediately. A type that is missing from the check constraint makes the whole transaction raise.

## Flow: an agent long-polls the JSON feed

**Entry:** `GET /v1/sessions/:code/events?after=&wait=&limit=`

1. **Trigger** — `index` parses `after`, `wait` and `limit` · `lib/c3_web/controllers/v1/event_controller.ex:index`
2. **Guard** — the `:feed` pipeline runs `AgentAuth` with `activity: false`: a poll does not count as session activity. It then rate-limits per token (see [sessions-and-agents](../sessions-and-agents/), [session-lifecycle](../session-lifecycle/)). A negative or non-integer value is rejected with `{:error, {:invalid, …}}` · `lib/c3_web/controllers/v1/event_controller.ex:parse_int`
3. **Logic** — `wait` is capped at `long_poll_max_wait` and `limit` is clamped to 1–100. `wait_after` subscribes, runs `list_after`, and if that returns nothing, blocks in `await` until a `seq > after` announcement arrives or the deadline passes · `lib/c3/events.ex:wait_after`, `lib/c3/events.ex:await`
4. **Persist / call** — reads ordered by `seq` with actor, thread and message (plus the message's thread) preloaded · `lib/c3/events.ex:list_after`
5. **Notify** — emits `[:c3, :long_poll, :stop]` telemetry with outcome `immediate`/`woken`/`timeout`, but only when `wait > 0` (see [metrics](../metrics/)) · `lib/c3/events.ex:wait_after`
6. **Respond** — `{events, last_seq}`. When nothing came, `last_seq` echoes `after`. Each event carries readable refs (`AG2`, `T3`, `T3.2`) and the dotted type · `lib/c3_web/controllers/v1/event_json.ex:index`, `lib/c3_web/controllers/v1/event_json.ex:event`

**Touch this flow when:** the event object shape changes, page or wait limits change, or long-poll latency needs to be measured.
**Breaks when:** a client passes a stale cursor and expects a push. If the node dies between a commit and its publish, the waiter just times out. Only re-polling with the same `after` returns the event, so clients must loop and must not trust one timeout as "nothing happened".

## Flow: an agent streams events over SSE

**Entry:** `GET /v1/sessions/:code/events/stream` (`Last-Event-ID` header or `?after=`)

1. **Trigger** — `stream` reads the resume cursor. The header wins over `?after=` · `lib/c3_web/controllers/v1/event_controller.ex:last_event_id`
2. **Guard** — the `[:sse, :feed]` pipelines apply. These routes skip `:v1`'s `accepts`, because `Accept: text/event-stream` would get a 406 there (comment on `pipeline :sse` in `lib/c3_web/router.ex`) · `lib/c3_web/controllers/v1/event_controller.ex:stream`
3. **Logic** — sends `x-accel-buffering: no` and `retry: 3000`, subscribes, then `deliver` queries `list_after` and either writes the events or waits in `listen` · `lib/c3_web/controllers/v1/event_controller.ex:deliver`, `lib/c3_web/controllers/v1/event_controller.ex:listen`
4. **Persist / call** — on each keepalive tick (`sse_keepalive` seconds), it reloads the agent. If the agent is still `:active`, it writes `: keepalive` and calls `Sessions.touch_seen`, so the keepalive counts as a sign of life · `lib/c3_web/controllers/v1/event_controller.ex:listen`
5. **Notify** — each event is framed `id: <seq>` / `event: <dotted type>` / `data: <event JSON>` · `lib/c3_web/controllers/v1/event_controller.ex:sse_event`
6. **Respond** — the stream ends after `session.closed`, after the caller's own `agent.left` (matched by `actor_agent_id`) or `agent.revoked` (matched by `payload["name"]`), after a chunk error, or when a keepalive tick finds the agent no longer active · `lib/c3_web/controllers/v1/event_controller.ex:ends_stream?`

**Touch this flow when:** reverse-proxy buffering problems, SSE reconnect behaviour, or new terminal event types.
**Breaks when:** a proxy buffers the response and the client sees nothing until close. Another case: an `agent.revoked` payload loses its `"name"` key, and the revoked agent's stream then never ends. `list_after` here uses the default limit of 100, so a large backlog is sent in several 100-event chunks.

## Flow: the watcher script waits for something that concerns it

**Entry:** `GET /v1/sessions/:code/watch?after=&wait=` (`text/plain`)

1. **Trigger** — `watch` parses `after` and `wait` and computes one deadline for the whole request · `lib/c3_web/controllers/v1/event_controller.ex:watch`
2. **Guard** — same `[:sse, :feed]` pipelines as the stream.
3. **Logic** — `watch_after` long-polls. It turns each event into a line with `C3.Watch.line/2`. While no line concerns the caller and time remains, it moves the cursor forward and polls again · `lib/c3_web/controllers/v1/event_controller.ex:watch_after`, `lib/c3/watch.ex:line`
4. **Persist / call** — `Events.wait_after` with the remaining time · `lib/c3/events.ex:wait_after`
5. **Respond** — a `cursor <seq>` line, then one line per relevant event. The cursor moves past irrelevant events too · `lib/c3_web/controllers/v1/event_controller.ex:watch`

**Touch this flow when:** the watcher wakes too often or not at all. Usually the fix is in `C3.Watch` (owned by [watcher-and-plugin](../watcher-and-plugin/)), not here.
**Breaks when:** a client re-sends its old `after` instead of the returned `cursor`. It then re-reads irrelevant events every time. Each internal re-poll that waits also emits its own long-poll telemetry event.

## Flow: an agent sends a heartbeat

**Entry:** `POST /v1/heartbeat`

1. **Guard** — the `:feed` pipeline. `AgentAuth` updates presence, not session activity.
2. **Respond** — `{ok, you, last_seen_at}` · `lib/c3_web/controllers/v1/event_controller.ex:heartbeat`

**Touch this flow when:** the presence semantics change (see [session-lifecycle](../session-lifecycle/)).

## Shared state

- `sessions.event_seq` — the per-session counter, on the session schema owned by [sessions-and-agents](../sessions-and-agents/). `append!` is its only incrementer here.
- PubSub topic `admin` — also carries `{:c3_admin, message}` from `notify_admin/1` for changes that leave no event (`lib/c3/events.ex:notify_admin`). [admin-ui](../admin-ui/) consumes it with `subscribe_admin/0` and reads `list_recent/3` and `last_at/2` (`lib/c3/events.ex:list_recent`, `lib/c3/events.ex:last_at`).
- The `@pending` process-dictionary key — set by `C3.Repo.transaction/2`. A nested transaction joins the outermost one's pending map.
- `C3.Config` keys `long_poll_max_wait` and `sse_keepalive` — owned by configuration.
