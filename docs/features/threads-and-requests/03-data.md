---
doc: features/threads-and-requests/03-data
repo: c3
kind: feature-data
anchored_to: fa64fbd
generated: 2026-10-02
---
# Threads and Requests — data

**Entry module:** `lib/c3/threads.ex:C3.Threads` · **Transport:** REST (`/v1`). The same context also serves the MCP tools; see `mcp-server`.

## Endpoints

All routes run through the `:agent` pipeline in `lib/c3_web/router.ex`. Threads are addressed by their readable ref (`T3`), and the token decides which session. Errors go through `C3Web.V1.FallbackController`, using the reasons listed in the `C3.Threads` moduledoc (`:thread_not_found`, `{:invalid, …}`, `{:forbidden, …}`, `{:conflict, …}`, `{:too_large, …}`, a changeset).

| Operation | Method / name | Handler | Input | Output | Side effects |
|---|---|---|---|---|---|
| list threads | `GET /v1/sessions/:code/threads` | `lib/c3_web/controllers/v1/thread_controller.ex:index` | `status` ∈ `@statuses`; `awaiting` accepts only `"me"` · `lib/c3_web/controllers/v1/thread_controller.ex:list_opts` | `lib/c3_web/controllers/v1/thread_json.ex:index` | — |
| open thread | `POST /v1/sessions/:code/threads` | `lib/c3_web/controllers/v1/thread_controller.ex:create` → `lib/c3/threads.ex:open_thread` | `title`, `body`, `to`, `attachments` | `201` · `lib/c3_web/controllers/v1/thread_json.ex:show` | one request per target; `thread_opened` event; possibly `thread_status_changed` |
| show thread | `GET /v1/threads/:id` | `lib/c3_web/controllers/v1/thread_controller.ex:show` | `since` (a message ref, parsed by `lib/c3/threads/refs.ex:parse_message_ref`) | `lib/c3_web/controllers/v1/thread_json.ex:show` | — |
| post | `POST /v1/threads/:id/messages` | `lib/c3_web/controllers/v1/thread_controller.ex:post_message` → `lib/c3/threads.ex:post_message` | `kind`, `body`, `to` (requests only), `reply_to`, `attachments` | `201` · `lib/c3_web/controllers/v1/thread_json.ex:posted` (`thread`, `messages`, `resolved`) | `message_posted` once per inserted message; a response resolves requests |
| claim | `POST /v1/threads/:id/claim` | `lib/c3_web/controllers/v1/thread_controller.ex:claim` → `lib/c3/threads.ex:claim` | `request_id` (optional) | `lib/c3_web/controllers/v1/thread_json.ex:action` + `claimed` | `request_claimed` once per newly claimed request |
| cancel | `POST /v1/threads/:id/cancel` | `lib/c3_web/controllers/v1/thread_controller.ex:cancel` → `lib/c3/threads.ex:cancel` | `request_id` (required), `reason` | `action` + `cancelled`, `note` | `request_cancelled`; when `reason` is present, a `note` plus `message_posted` |
| finish | `POST /v1/threads/:id/finish` | `lib/c3_web/controllers/v1/thread_controller.ex:finish` → `lib/c3/threads.ex:finish` | `force` (`true` or `"true"`) | `action` + `finished`, `cancelled` | `request_cancelled` for each pending request, with `reason: "thread finished"` |
| reopen | `POST /v1/threads/:id/reopen` | `lib/c3_web/controllers/v1/thread_controller.ex:reopen` → `lib/c3/threads.ex:reopen` | — | `action` + `reopened` | `thread_status_changed` (finished → derived) |
| inbox | `GET /v1/inbox` | `lib/c3_web/controllers/v1/inbox_controller.ex:show` | — | `lib/c3_web/controllers/v1/inbox_json.ex:show` (`you`, `empty`, `threads[].requests`, `cancelled`, `alerts`) | **marks notices as seen**: `C3.Sessions.take_notices` |

Traps in the endpoints:
- **`GET /v1/inbox` is not idempotent.** Cancellations and alerts appear exactly once, because reading them consumes them (`lib/c3_web/controllers/v1/inbox_controller.ex:show`). A client that retries or drops the response loses them. The requests themselves are re-derived on every call.
- `:code` on the thread-list and create routes is only checked against the token, in `C3Web.Plugs.AgentAuth` (`same_session?`). The controller reads `current_session` and ignores the code.
- `finish` and `reopen` are no-ops on a thread that is already in that state (`changed: false`), not errors. `post_message` and `claim` on a finished thread return a `409` "reopen it first" (`lib/c3/threads/guards.ex:rollback_finished`). `cancel` does **not** check `finished_at`. Finishing cancels every pending request anyway, so in practice cancelling on a finished thread is a `409` for "already cancelled".
- Claiming with no `request_id` takes every pending request addressed to the agent (`lib/c3/threads/queries.ex:addressed_requests`). It is a `409` only if the agent ends up holding nothing; the `409` carries `claimed_by` holders.
- A `response` without `reply_to` resolves **every** request the author may answer and is not held by someone else (`lib/c3/threads/guards.ex:resolvable!`). `reply_to` is filled in afterwards only when exactly one request was resolved (`single/1` in `lib/c3/threads.ex`). A response whose `reply_to` points to a non-request resolves nothing. Resolving an `open` request claims it implicitly: `claimed_by_agent_id` is set as it moves to `done` (`resolve!` in `lib/c3/threads.ex`).
- `to` on a non-request is an `{:invalid, …}` error (`lib/c3/threads/guards.ex:targets_for`), not ignored.
- Cancelling is allowed for the request's author **or** the thread opener (`lib/c3/threads/guards.ex:cancellable_request!`). Finishing and reopening are opener-only (`check_opened_by!`). `lib/c3/threads.ex:admin_finish` bypasses that check, always forces, and records `cancelled_by: "admin"`.

## Schema

| Entity | Table / type | Key fields | Constraints | Defined |
|---|---|---|---|---|
| Thread | `threads` | `number` (per session), `title`, `status`, `finished_at`, `last_message_at`, `lock_version`, `opened_by_agent_id` | unique `[:session_id, :number]`; `threads_status_check`; `threads_finished_at_check` (`finished_at` is present iff `status == :finished`); title 1–200 | `lib/c3/threads/thread.ex:C3.Threads.Thread` |
| Message | `messages` | `number` (per thread), `kind` (`request`/`response`/`note`/`system`), `body`, `to_target`/`to_agent_id`/`to_label`, `request_state`, `claimed_by_agent_id`, `claimed_at`, `resolved_at`, `reply_to_message_id`, `session_id` | unique `[:thread_id, :number]`; one CHECK per conditional field (`messages_to_target_check`, `messages_request_state_check`, `messages_claimed_by_check`, …); body ≤ `max_body_bytes` (bytes, not characters) | `lib/c3/threads/message.ex:C3.Threads.Message` |
| Derived state | (not stored) | `status`, `awaiting`, `processing_by` | — | `lib/c3/threads/derivation.ex:derive` |
| Target | (value) | `{:agent, Agent}` · `{:label, l}` · `:any` | — | `lib/c3/threads/targets.ex:resolve` |

Stored vs derived:
- **`threads.status` is a stored cache** of `Derivation.derive`. Only `apply_state!` in `lib/c3/threads.ex` writes it, inside the same transaction as the write that changed the requests. Do not write it from anywhere else, and do not add a migration to "compute" it.
- **`awaiting` and `processing_by` are never stored.** They are recomputed per read by `lib/c3/threads/queries.ex:states` from `request_rows`. `lib/c3_web/controllers/v1/thread_json.ex:summary` mixes the cached `status` with these derived lists. Both are always filled: a `pending` thread can still have a non-empty `processing_by`.
- Readable ids (`T3`, `T3.5`, `AG2`) are formatted at the edge (`lib/c3/threads/refs.ex`). Database ids never leave the API, with one exception: attachment `id` in `lib/c3_web/controllers/v1/thread_json.ex:attachment`.
- One request is stored per target. A post to `["AG2","label:x"]` creates two consecutively numbered `request` rows with the same body (`insert_requests!` in `lib/c3/threads.ex`). Message numbers come from `max(number)+1` under the thread lock. Thread numbers come from `sessions.next_thread_number` (`next_thread_number!`).
- The body is append-only. Only the `request_*`, `claimed_*` and `resolved_at` columns change after insert (`lib/c3/threads/message.ex` moduledoc). A request can be `done` with or without `claimed_by_agent_id` (`validate_claimed_by`). `:system` messages have no author. Nothing in `lib/c3/threads.ex` inserts one.

Request states: `open → claimed → done`; `open|claimed → cancelled`; `claimed → open` happens on leave (`release_claims!`) and on claim expiry (`expire_claims`). Status precedence: `finished > pending > processing > answered` (`lib/c3/threads/derivation.ex:derive`). The derived status values are the same as the ones the private spec designed, but the spec's per-session process was dropped. Concurrency is the row lock described below.

## Cache, events and invalidation

- Every write calls `lock_thread!` first. It is an `UPDATE` that bumps `lock_version` and `updated_at`, and it serializes writers per thread. A claim is also a conditional `UPDATE … WHERE request_state = 'open'`, so of two racing claimers exactly one wins. The loser gets `409` "Nothing to claim" or "already claimed".
- Events are appended through `C3.Events.append!` inside the transaction: `thread_opened`, `message_posted`, `request_claimed`, `request_cancelled`, `request_claim_expired`, `thread_status_changed`. Delivery, `seq`, and SSE are owned by `event-feed`. The watcher's wake rules are owned by `watcher-and-plugin`.
  - `message_posted.resolved_for` lists the authors of the resolved requests. The watcher uses it to wake the asker.
  - `request_cancelled.claimed_by` tells the worker to stop. The same event reappears as an inbox `cancelled` entry (`lib/c3_web/controllers/v1/inbox_json.ex:cancellation`), but only until it is read once.
  - `thread_status_changed` is emitted only when `status` actually moved (`apply_state!`). When `finish` emits it, it carries `cancelled` in the payload.
- **Invalidators that live outside this feature** (all of them change requests and must call back into the status cache):
  - `C3.Sessions.leave/1` → `lib/c3/threads.ex:release_claims!`, then `refresh_threads!`. If it skips `refresh_threads!`, the thread stays `processing` while its requests are `open`.
  - `C3.Sweeper` → `lib/c3/threads.ex:expire_claims`. It releases claims that are older than `claim_ttl` **and** whose agent has been silent for that long (`agents.last_seen_at`), in open sessions only.
  - The admin UI → `lib/c3/threads.ex:admin_finish`.
- `last_message_at` drives list ordering (`list_threads` orders by `last_message_at desc, number desc`). It is bumped on post and on cancel-with-reason, **not** on claim or finish.

## Scoping

- Every lookup is narrowed to the token's session: `fetch_thread` matches `session_id` and `number` (`lib/c3/threads/queries.ex:fetch_thread`). A ref from another session, or a malformed ref, returns `:thread_not_found` and never says forbidden. Token auth is owned by `sessions-and-agents` (`C3Web.Plugs.AgentAuth`).
- Message refs are scoped to their thread. Writing `T4.2` while acting on `T3` is `{:invalid, "… is not a message of T3"}` (`lib/c3/threads/refs.ex:parse_message_ref`). A bare `2` or `5` is accepted.
- "Addressed to me" is `lib/c3/threads/queries.ex:addressed_to`. It matches: my agent id; or `any` **from someone else**; or my label, when I have one. Consequences:
  - An agent without a label never sees label requests.
  - A label target needs no current holder (`lib/c3/threads/targets.ex` moduledoc). An agent that joins later with that label inherits it.
  - Named targets must be `active` agents of the session and never the author (`check/3` in `lib/c3/threads/targets.ex`). Names are normalized to upper case.
- Inbox (`lib/c3/threads/queries.ex:inbox`) shows `open` requests addressed to me plus `claimed` requests I hold. It does not filter on thread `finished_at`, but finishing cancels everything pending, so a finished thread has nothing to show. `awaiting=me` on the thread list only counts `open` requests, not ones I already claimed (`filter_awaiting`).

## Local state

None. There is no per-session process, no ETS, and no Presence. The private spec designed them; the code dropped them. All state is in `threads` and `messages`, so a restart loses nothing. Claims abandoned by a crashed agent are only released by `expire_claims` or by leave.
