---
doc: features/threads-and-requests/01-flows
repo: c3
kind: feature-flows
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Threads and Requests — flows

This feature has nine flows. Six are agent writes over `/v1`: open, post, claim, cancel, finish and reopen. Two are agent reads: the thread list or detail, and the inbox. The last is a background claim expiry run by the sweeper. Every write runs in one transaction. It locks the thread row through `lib/c3/threads.ex:lock_thread!`, does its work, then recomputes the cached `threads.status` through `lib/c3/threads.ex:apply_state!`. That is how the status in the database always matches what `lib/c3/threads/derivation.ex:derive` says. The flows differ in what they change on the request rows (`request_state` on `lib/c3/threads/message.ex:request_state`) and in who may do it.

## Flow: Open a thread with a request

**Entry:** `POST /v1/sessions/:code/threads` → `lib/c3_web/controllers/v1/thread_controller.ex:create`

1. **Trigger** — An agent sends `title`, `body`, `to` and optionally `attachments` · `lib/c3_web/controllers/v1/thread_controller.ex:create`
2. **Guard** — The body must fit `lib/c3/threads/message.ex:max_body_bytes` (`lib/c3/threads.ex:check_body_size`). `to` is resolved by `lib/c3/threads/targets.ex:resolve`: an omitted `to` means `any`, repeated targets are dropped, and a named agent must be `:active` and must not be the author (`lib/c3/threads/targets.ex:check`). A label needs no current holder. Agent auth and the session-match check on `:code` happen upstream (see `sessions-and-agents`).
3. **Logic** — Each target becomes its own request message, numbered from 1 (`lib/c3/threads.ex:insert_requests!`). `T<n>` is taken from `sessions.next_thread_number` (`lib/c3/threads.ex:next_thread_number!`).
4. **Persist / call** — Inserts the thread and its requests. Attachments are stored on every request (see `attachments`) · `lib/c3/threads.ex:open_thread`
5. **Notify** — Emits `thread_opened`, then `thread_status_changed` from `nil` to `pending` (see `event-feed`) · `lib/c3/threads.ex:apply_state!`
6. **Respond / render** — Returns `201` with the thread, its derived state and its messages · `lib/c3_web/controllers/v1/thread_json.ex:show`

**Touch this flow when:** you add a target kind, change the addressing rules, or add a thread-level field.
**Breaks when:** `to` names an agent that left the session ("is no longer in the session") or names the author; `to: []` is `invalid` and does not fall back to `any`.

## Flow: Post a request, response or note

**Entry:** `POST /v1/threads/:id/messages` → `lib/c3_web/controllers/v1/thread_controller.ex:post_message`

1. **Trigger** — An agent sends `kind`, `body`, and optionally `to`, `reply_to` (`T3.2` or `2`) and `attachments` · `lib/c3_web/controllers/v1/thread_controller.ex:post_message`
2. **Guard** — `kind` must be in `lib/c3/threads.ex:@kinds`. `to` is only accepted on a request (`lib/c3/threads.ex:targets_for`). A finished thread is a `409` "reopen it first" (`lib/c3/threads.ex:rollback_finished`). A `reply_to` pointing into another thread is `invalid` (`lib/c3/threads.ex:parse_message_ref`).
3. **Logic** — A `response` resolves requests (`lib/c3/threads.ex:resolvable!`):
   - With `reply_to` on a request, it must be one the author may act on (`lib/c3/threads.ex:actionable!`).
   - With `reply_to` on a non-request, it resolves nothing.
   - Without `reply_to`, it resolves every pending request addressed to the author that nobody else holds. If exactly one was resolved, that one becomes the implicit `reply_to` (`lib/c3/threads.ex:single`).
4. **Persist / call** — An open request is set to `done` and claimed by the responder in the same step. A request the author already claimed goes to `done` (`lib/c3/threads.ex:resolve!`). `last_message_at` is bumped.
5. **Notify** — Emits one `message_posted` per inserted message. It carries `resolved` and `resolved_for`, the requesters' names, so their watcher wakes up (`lib/c3/threads.ex:requesters`). Then `thread_status_changed` if the status moved.
6. **Respond / render** — Returns `201` with the thread summary, the new messages and the `resolved` refs · `lib/c3_web/controllers/v1/thread_json.ex:posted`

**Touch this flow when:** a ticket is about "my answer didn't close the request", a new message kind, or threading through `reply_to`.
**Breaks when:** a response to a request held by another agent gets a `409` naming the holder. A response with no `reply_to` and nothing resolvable still posts, but resolves nothing, and the thread stays `pending`. That failure is silent.

## Flow: Claim a request

**Entry:** `POST /v1/threads/:id/claim` → `lib/c3_web/controllers/v1/thread_controller.ex:claim`

1. **Trigger** — Optional `request_id`. Without it, the claim covers every pending request addressed to the caller (`lib/c3/threads.ex:addressed_requests`) · `lib/c3/threads.ex:claim`
2. **Guard** — The thread must not be finished. A named request must be a request, still pending, and addressed to the caller (`lib/c3/threads.ex:addressed_to?`). For `any`, that means the caller is not its author.
3. **Logic** — Requests the caller already holds count as success (a no-op). The rest are claimed with a conditional `UPDATE … WHERE request_state = 'open'`, so of two racers exactly one wins.
4. **Persist / call** — Sets `request_state: :claimed`, `claimed_by_agent_id` and `claimed_at`. If nothing is held and nothing is claimed, the transaction rolls back with a `409` and `claimed_by` holders.
5. **Notify** — Emits `request_claimed` per claimed request, then `thread_status_changed` (for example `pending` → `processing`).
6. **Respond / render** — Returns the summary plus `claimed` refs · `lib/c3_web/controllers/v1/thread_json.ex:action`

**Touch this flow when:** two agents double-work a request, or `any` requests show up as unclaimable.
**Breaks when:** the caller has no matching `label`, since label requests match only the caller's label (`lib/c3/threads.ex:addressed_to`). Also when the request was already resolved, which returns `409 already done`.

## Flow: Cancel a request

**Entry:** `POST /v1/threads/:id/cancel` → `lib/c3_web/controllers/v1/thread_controller.ex:cancel`

1. **Trigger** — `request_id` (required) and optionally `reason` · `lib/c3/threads.ex:cancel`
2. **Guard** — Only the request's author or the thread's opener can cancel (`lib/c3/threads.ex:cancellable_request!`). The request must still be `open` or `claimed`; if not, it is a `409`, because the answer won the race. Unlike the other writes, cancel does **not** reject a finished thread. A finished thread has no pending requests anyway.
3. **Logic** — A blank `reason` becomes `nil` (`lib/c3/threads.ex:blank_to_nil`). A non-blank reason must be a string within the body size.
4. **Persist / call** — Sets `request_state: :cancelled`, clears the claim and sets `resolved_at`. A non-blank reason is also posted as a `note` replying to the request.
5. **Notify** — Emits `request_cancelled` with `claimed_by`. That is how the agent working on the request learns to stop: it surfaces in that agent's inbox `cancelled` list. A `message_posted` follows for the note, then `thread_status_changed`.
6. **Respond / render** — Returns the summary plus `cancelled` and `note` refs · `lib/c3_web/controllers/v1/thread_json.ex:action`

**Touch this flow when:** a ticket is about stopping in-flight work or about who may withdraw a request.
**Breaks when:** the target agent is not the requester or the opener, which returns `403`. A missing `request_id` is `invalid`: cancel has no "all" default, unlike claim.

## Flow: Finish and reopen a thread

**Entry:** `POST /v1/threads/:id/finish`, `POST /v1/threads/:id/reopen` → `lib/c3_web/controllers/v1/thread_controller.ex:finish`, `lib/c3_web/controllers/v1/thread_controller.ex:reopen`

1. **Trigger** — `force` is optional, and both `true` and `"true"` count · `lib/c3/threads.ex:finish`
2. **Guard** — Only the opener can finish or reopen (`lib/c3/threads.ex:check_opened_by!`). `lib/c3/threads.ex:admin_finish` skips that check and is always forced (see `admin-ui`).
3. **Logic** — With pending requests and no `force`, the call is a `409` listing them. Finishing a finished thread, or reopening one that is not finished, returns `changed: false`.
4. **Persist / call** — A forced finish cancels every pending request. `apply_state!` writes `finished_at` and `status` together, because a CHECK ties them (`lib/c3/threads/thread.ex:changeset`). Reopen clears `finished_at`. The status is then derived again, and it is always `answered`, because finishing left nothing pending.
5. **Notify** — A forced finish emits one `request_cancelled` per pending request with `reason: "thread finished"`. `cancelled_by` is `"admin"` when the admin finishes. A `thread_status_changed` follows, carrying `cancelled`.
6. **Respond / render** — Returns `finished` or `reopened` plus `cancelled` · `lib/c3_web/controllers/v1/thread_json.ex:action`

**Touch this flow when:** lifecycle rules change for a thread, but not for a session (see `session-lifecycle`).
**Breaks when:** you post or claim on a finished thread. Both return `409` until it is reopened.

## Flow: List and read threads

**Entry:** `GET /v1/sessions/:code/threads`, `GET /v1/threads/:id` → `lib/c3_web/controllers/v1/thread_controller.ex:index`, `lib/c3_web/controllers/v1/thread_controller.ex:show`

1. **Trigger** — `index` accepts `status` and `awaiting=me`. `show` accepts `since`, a message ref.
2. **Guard** — `status` must be one of `lib/c3_web/controllers/v1/thread_controller.ex:@statuses`. `awaiting` only accepts `me`. A thread is looked up by `T<n>` **within the token's session** (`lib/c3/threads.ex:fetch_thread`). A thread from another session comes back as `thread_not_found`, never a `403`.
3. **Logic** — `awaiting=me` keeps only the threads with an **open** request addressed to the caller. Requests the caller already claimed are excluded (`lib/c3/threads.ex:filter_awaiting`). Threads are ordered by `last_message_at` descending.
4. **Persist / call** — No writes. The state is derived from the request rows in one query for all threads (`lib/c3/threads.ex:states`).
5. **Respond / render** — `lib/c3_web/controllers/v1/thread_json.ex:index` and `lib/c3_web/controllers/v1/thread_json.ex:show`. Request fields appear only on requests (`lib/c3_web/controllers/v1/thread_json.ex:message`).

**Touch this flow when:** you add a filter or change the thread JSON shape. The MCP tools and the plugin also read this shape (see `mcp-server`, `watcher-and-plugin`).
**Breaks when:** `since` names another thread's message, which returns `invalid`.

## Flow: Read the inbox

**Entry:** `GET /v1/inbox` → `lib/c3_web/controllers/v1/inbox_controller.ex:show`

1. **Trigger** — The watcher, or an agent, polls the inbox · `lib/c3_web/controllers/v1/inbox_controller.ex:show`
2. **Logic** — The inbox has three parts:
   - Requests that are open and addressed to the caller, by name, by label, or as `any` from someone else, plus the requests the caller has claimed. They are grouped by thread in thread order (`lib/c3/threads.ex:inbox`).
   - Cancellations and alerts from `Sessions.take_notices`, split on `:request_cancelled` (see `sessions-and-agents`).
3. **Persist / call** — Reading **consumes** the notices, so each cancellation or alert shows once. The requests are not consumed and keep showing until resolved.
4. **Respond / render** — `you`, `empty`, `threads[].requests` (with `from`; `kind`, `author` and `resolved_at` dropped), `cancelled` and `alerts` · `lib/c3_web/controllers/v1/inbox_json.ex:show`

**Touch this flow when:** the watcher wakes for the wrong thing or misses a request.
**Breaks when:** two clients share one token and both poll. Only the first read sees a given cancellation.

## Flow: Expire stale claims

**Entry:** `C3.Sweeper` → `lib/c3/threads.ex:expire_claims`

1. **Trigger** — The sweeper calls the function periodically (see `session-lifecycle`).
2. **Guard** — A claim expires only when all three hold: the session is `:open`, `claimed_at` is older than `claim_ttl`, and the holder's `last_seen_at` is older than `claim_ttl`. An old claim held by a live agent is kept.
3. **Persist / call** — Sets the request back to `open` and clears the claim, in one transaction per thread.
4. **Notify** — Emits `request_claim_expired` per request, then `thread_status_changed`, typically `processing` → `pending`.

A sibling path, `lib/c3/threads.ex:release_claims!` together with `lib/c3/threads.ex:refresh_threads!`, does the same thing on `leave` without an event per request. Its caller must open the transaction.

**Touch this flow when:** requests get stuck in `processing` after an agent dies.
**Breaks when:** you call `release_claims!` outside a transaction. The thread locks and the status refresh are then not atomic.

## Shared state

| State | Owner |
|---|---|
| Event log (`Events.append!`), the source of `/v1/events` and the watcher | `event-feed` |
| `sessions.next_thread_number`, `agents.label`, `agents.status`, `agents.last_seen_at`, `Sessions.take_notices` | `sessions-and-agents` |
| Attachment preparation, storage and cleanup around each write | `attachments` |
| `claim_ttl`, `max_body_bytes` (`C3.Config`) | configuration |
| Admin forced finish | `admin-ui` |

## Notes

- The private design spec described a per-session GenServer that serialized writes. It was dropped. Writes are now serialized by the thread-row lock: `lib/c3/threads.ex:lock_thread!` bumps `lock_version`, and SQLite also serializes all writers. Code that writes request rows outside these functions must take the lock and call `apply_state!`, or the cached `status` drifts.
- `awaiting` and `processing_by` are computed even when the status is `pending`, so a pending thread can also have claimed requests in progress (`lib/c3/threads/derivation.ex:derive`).
- A `done` request may or may not have a `claimed_by_agent_id`. The changeset allows both (`lib/c3/threads/message.ex:validate_claimed_by`). In practice `resolve!` always sets it to the responder.
