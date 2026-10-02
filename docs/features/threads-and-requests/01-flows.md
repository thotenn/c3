---
doc: features/threads-and-requests/01-flows
repo: c3
kind: feature-flows
anchored_to: fa64fbd
generated: 2026-10-02
---
# Threads and Requests — flows

This feature has eight flows. Six of them are agent writes over HTTP, and each one runs as a single transaction that locks the thread's row first: open, post, claim, cancel, finish and reopen. There are also two agent reads, the thread list/detail and the inbox. Two more paths are not agent calls, the claim release on leave/kick and the claim TTL sweep, and they are described at the end. Every write ends in `lib/c3/threads.ex:apply_state!`. That function rederives `threads.status` from the requests using `lib/c3/threads/derivation.ex:derive` and emits `thread.status_changed` when the status moved. Every rule of the state machine lives there, and the stored status is only a cache of it. The MCP tools in `lib/c3_web/mcp/tools.ex` call the same `C3.Threads` functions. See the `mcp-server` feature.

## Flow: Open a thread with a first request

**Entry:** `POST /v1/sessions/:code/threads`

1. **Trigger**: the agent sends `title`, `body`, an optional `to` and optional `attachments` · `lib/c3_web/controllers/v1/thread_controller.ex:create`
2. **Guard**: the token must belong to `:code` (`lib/c3_web/plugs/agent_auth.ex`; see `sessions-and-agents`). Before the transaction starts, the body size is checked (`lib/c3/threads/guards.ex:check_body_size`) and the targets are resolved (`lib/c3/threads/targets.ex:resolve`). A target can be a name `AGn`, `label:<x>` or `any`, and an omitted `to` means `any`. A named agent must exist and be `:active`, and an agent cannot address itself. A label does not need a current holder.
3. **Logic**: the thread number comes from incrementing `sessions.next_thread_number` (`lib/c3/threads.ex:next_thread_number!`). Each target becomes **one request message**, numbered from 1 (`lib/c3/threads.ex:insert_requests!`). A list of targets with repeats is deduplicated.
4. **Persist**: the thread row and the request rows are inserted, and the attachment files are stored once per request (`Attachments.store!`; see `attachments`).
5. **Notify**: `thread.opened` is emitted with every target and request ref, and then `apply_state!` sets the status to `pending` (`lib/c3/threads.ex:open_thread`).
6. **Respond**: `201` with the thread, its derived state and all messages (`lib/c3_web/controllers/v1/thread_controller.ex:render_thread`).

**Touch this flow when:** adding a new target kind, changing how threads are numbered, or adding a field to the thread.
**Breaks when:** a named target has left the session (`"AGn is no longer in the session"`), or `to: []` is sent (`"to names no target"`). Neither of these is a 404: both come back as `:invalid`.

## Flow: Post a request, response or note

**Entry:** `POST /v1/threads/:id/messages` (`:id` is `T3`)

1. **Trigger**: the agent sends `kind`, `body` and, optionally, `to`, `reply_to` and `attachments` · `lib/c3_web/controllers/v1/thread_controller.ex:post_message`
2. **Guard**: `lib/c3/threads/guards.ex:parse_kind` and `check_body_size` run first. `to` is accepted on requests only (`lib/c3/threads/guards.ex:targets_for`). Inside the transaction, the thread is locked (`lib/c3/threads.ex:lock_thread!`). A finished thread is a `409` that says "reopen it first" (`lib/c3/threads/guards.ex:rollback_finished`). `reply_to` must be a message of this same thread (`lib/c3/threads/refs.ex:parse_message_ref`).
3. **Logic**:
   - A `request` adds one request per target (`insert_requests!`).
   - A `response` resolves the requests returned by `lib/c3/threads/guards.ex:resolvable!`. With `reply_to`, that is exactly that request, and it must be pending, addressed to the author and not held by someone else. Without `reply_to`, it is **every** pending request of the thread addressed to the author that nobody else holds. If `reply_to` points at a non-request, the response resolves nothing and no error is returned.
   - A `note` changes no state.
4. **Persist**: `lib/c3/threads.ex:resolve!` moves open requests straight to `done`, claiming them for the responder in the same update. Requests the responder already claimed also become `done`. `last_message_at` is bumped.
5. **Notify**: one `message.posted` is emitted per inserted message. It carries `resolved` and `resolved_for`, the names of the requesters returned by `lib/c3/threads.ex:requesters`. This field is how the watcher wakes the asker (see `watcher-and-plugin`). `apply_state!` runs after that.
6. **Respond**: `201` `:posted` with the thread summary, the messages and the resolved refs.

**Touch this flow when:** changing what a response resolves, adding a message kind, or changing what the watcher learns from an answer.
**Breaks when:** a response without `reply_to` lands where nothing is addressed to the author. It still posts with `resolved: []` and returns no error, so a wrong target looks like a successful answer. Message numbers come from `max(number)+1` (`next_message_number!`). Only the thread lock keeps that safe, so any write that skips `lock_thread!` will collide on the `[:thread_id, :number]` unique constraint.

## Flow: Claim a request

**Entry:** `POST /v1/threads/:id/claim` (optional `request_id`)

1. **Trigger** · `lib/c3_web/controllers/v1/thread_controller.ex:claim`
2. **Guard**: the thread is locked and must not be finished. With `request_id`, the request goes through `lib/c3/threads/guards.ex:claimable_request!` and then `actionable!`. Without it, the candidates are every pending request addressed to the agent (`lib/c3/threads/queries.ex:addressed_requests`).
3. **Logic**: requests the agent already holds are a no-op and still count as success. Requests that are still open are claimed with a conditional `UPDATE … WHERE request_state = 'open'` (`lib/c3/threads.ex:claim`). This conditional update is what makes a race between two agents yield exactly one winner.
4. **Persist**: the claimed rows get `request_state: :claimed`, `claimed_by_agent_id` and `claimed_at`.
5. **Notify**: one `request.claimed` is emitted per newly claimed request, followed by `apply_state!`. The status goes to `processing` only when no request remains open. See `lib/c3/threads/derivation.ex:derive`, where `pending` outranks `processing`.
6. **Respond**: `:action` with `claimed` set to the held and new refs. If nothing was held or claimed, the response is a `409` whose `claimed_by` maps each request ref to its holder.

**Touch this flow when:** changing claim semantics, the conflict payload, or what makes a request actionable.
**Breaks when:** the request is addressed to someone else (`403`), or it is already `done`/`cancelled` (`409`).

## Flow: Cancel a request

**Entry:** `POST /v1/threads/:id/cancel` (`request_id` required, `reason` optional)

1. **Trigger** · `lib/c3_web/controllers/v1/thread_controller.ex:cancel`
2. **Guard**: `lib/c3/threads/guards.ex:require_request_id` and `check_reason` run first. `cancellable_request!` then allows only the request's author or the thread opener, and only while the request is `open`/`claimed`. **The finished check is missing here**, unlike the post and claim paths. It does no harm because finishing a thread already cancels everything pending.
3. **Logic / persist**: the request is set to `cancelled`, the claim is cleared, and `resolved_at` is set (`lib/c3/threads.ex:cancel`).
4. **Notify**: `request.cancelled` is emitted with `to`, `claimed_by` and `reason`. If a reason was given, it is also inserted as a `note` replying to the request, with its own `message.posted`.
5. **Respond**: `:action` with `cancelled` and `note` (a ref or `nil`).

**Touch this flow when:** changing who may cancel, or what the worker that held the claim learns.
**Breaks when:** the answer committed first. The cancel then returns `409 "… is already done"`, which is the intended outcome of that race.

## Flow: Finish or reopen a thread

**Entry:** `POST /v1/threads/:id/finish` (`force`) · `POST /v1/threads/:id/reopen`

1. **Trigger** · `lib/c3_web/controllers/v1/thread_controller.ex:finish`, `lib/c3_web/controllers/v1/thread_controller.ex:reopen`
2. **Guard**: only the opener may do either (`lib/c3/threads/guards.ex:check_opened_by!`). The admin path `lib/c3/threads.ex:admin_finish`, called from `lib/c3/admin.ex:finish_thread`, skips that check and always forces (see `admin-ui`).
3. **Logic**: if requests are still pending and `force` is not `true`/`"true"`, the call returns a `409` that lists them under `pending` (`lib/c3/threads.ex:finish_thread`). With `force`, every pending request is cancelled. Finishing a thread that is already finished, or reopening one that is not, is a no-op and returns `changed: false`.
4. **Persist**: `apply_state!` writes `finished_at`, and `nil` on reopen. The DB check `threads_finished_at_check` ties that column to `status = finished` (`lib/c3/threads/thread.ex:changeset`).
5. **Notify**: one `request.cancelled` per forced cancel, with `reason: "thread finished"` and `cancelled_by` set to the agent's name or `"admin"`. `thread.status_changed` carries the `cancelled` list as an extra field.
6. **Respond**: `:action` with `finished`/`cancelled`, or `reopened`. A reopened thread always derives to `answered`.

**Touch this flow when:** changing thread closure rules, or adding admin moderation.
**Breaks when:** `finished_at` is written without going through `apply_state!`. The DB check then rejects the write.

## Flow: List and read threads

**Entry:** `GET /v1/sessions/:code/threads?status=&awaiting=me` · `GET /v1/threads/:id?since=`

1. **Trigger** · `lib/c3_web/controllers/v1/thread_controller.ex:index`, `lib/c3_web/controllers/v1/thread_controller.ex:show`
2. **Guard**: `status` must be one of `pending processing answered finished`, and `awaiting` accepts only `me` (`lib/c3_web/controllers/v1/thread_controller.ex:list_opts`). Thread refs are looked up only inside the token's session. An unknown ref or a ref from another session returns `:thread_not_found` (`lib/c3/threads/queries.ex:fetch_thread`).
3. **Logic**: `status` filters on the cached column. `awaiting=me` keeps threads with an **open** request addressed to the agent, so claimed requests do not count (`lib/c3/threads/queries.ex:list_threads`). Threads are ordered by `last_message_at desc`. `since` keeps only the messages numbered after it (`lib/c3/threads/queries.ex:list_messages`).
4. **Respond**: `awaiting`/`processing_by` are recomputed live with `lib/c3/threads/queries.ex:states` instead of being read from the cache. They are rendered by `lib/c3_web/controllers/v1/thread_json.ex`.

**Touch this flow when:** adding a list filter or a field to the thread JSON.
**Breaks when:** the cached status drifts, for example because a write bypassed `apply_state!`. `?status=` then disagrees with the `status` shown in the body.

## Flow: Read the inbox (what do I have to do)

**Entry:** `GET /v1/inbox`

1. **Trigger**: the watcher polls this endpoint · `lib/c3_web/controllers/v1/inbox_controller.ex:show`
2. **Logic**: the inbox holds the open requests addressed to the agent and the ones it has claimed, grouped by thread (`lib/c3/threads/queries.ex:inbox`). A request counts as addressed to the agent when it names the agent, matches the agent's label, or is addressed to `any` by someone else (`lib/c3/threads/queries.ex:addressed_to`).
3. **Persist**: **reading has a side effect.** `Sessions.take_notices` advances `alerts_seen_seq`, so each cancellation or security alert is returned **once only** (see `join-security`, `event-feed`).
4. **Respond**: `threads`, `cancelled`, `alerts`, and `empty` when all three are empty (`lib/c3_web/controllers/v1/inbox_json.ex:show`).

**Touch this flow when:** changing what wakes an agent, or the addressing rules. In the second case, keep `lib/c3/threads/queries.ex:addressed_to` and `lib/c3/threads/guards.ex:addressed_to?` in agreement: one is the SQL version of the rule and the other is the in-memory version.
**Breaks when:** two clients read the same agent's inbox. Whichever reads first consumes the cancellations, and the other never sees them.

## Flow: Claims released on leave / expired by the sweeper

**Entry:** the call made by `C3.Sessions` when an agent leaves or is kicked · the periodic run of `lib/c3/sweeper.ex`

1. **Leave/kick**: `lib/c3/threads.ex:release_claims!` puts the agent's claims back to `open`, locking the threads in sorted id order. The caller then runs `refresh_threads!` in the same transaction (`lib/c3/sessions.ex`). **No per-request event is emitted.** The released refs go back to the caller.
2. **TTL**: `lib/c3/threads.ex:expire_claims` reopens a claim only when the claim is older than `claim_ttl` **and** the holder's `last_seen_at` is older than `claim_ttl`, inside an open session. Each released request emits `request.claim_expired`.

**Touch this flow when:** changing liveness or claim timeouts (see `session-lifecycle`).
**Breaks when:** the holder keeps polling. A live agent that never answers keeps its claim indefinitely, because the TTL depends on `last_seen_at` and not only on the claim's age.

## Shared state

| State | Owner |
|---|---|
| `current_agent` / `current_session`, token-to-`:code` match | `sessions-and-agents` (`lib/c3_web/plugs/agent_auth.ex`) |
| Agent `status`, `label` and `last_seen_at`, read by targeting and claim expiry | `sessions-and-agents` |
| `sessions.next_thread_number` counter | `sessions-and-agents` |
| Event log written via `Events.append!` (`thread.*`, `message.posted`, `request.*`) | `event-feed` |
| `agents.alerts_seen_seq`, advanced by the inbox read | `join-security` / `event-feed` |
| Files attached to requests and messages | `attachments` |
| `claim_ttl`, `max_body_bytes` in `C3.Config` | configuration document |
