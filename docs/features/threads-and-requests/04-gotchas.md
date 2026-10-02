---
doc: features/threads-and-requests/04-gotchas
repo: c3
kind: feature-gotchas
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Threads and Requests — gotchas

## Non-obvious behaviour

### `threads.status` is a cache, and only `apply_state!` may write it
The status column looks like normal state, but it is really the stored result of `C3.Threads.Derivation`. It is recomputed inside every write transaction. If you change a request's `request_state` and skip `apply_state!`, the thread's status falls out of date and nothing reports it. Code that changes requests from outside the context (for example leaving a session) must call `refresh_threads!` in the same transaction. · `lib/c3/threads.ex:apply_state!` · `lib/c3/threads.ex:refresh_threads!` · `lib/c3/threads/thread.ex:changeset`
**Costs you:** `GET /v1/threads?status=pending` and the `thread.status_changed` events stop matching the requests. The status filter reads the cached column (`lib/c3/threads.ex:filter_status`), while `awaiting`/`processing_by` are recomputed on every read (`lib/c3/threads.ex:states`). So a single response can contradict itself.

### `pending` beats `processing`
When a thread has both open and claimed requests, its status is `pending`. `processing_by` is still filled in. A thread is `processing` only when no request is open. · `lib/c3/threads/derivation.ex:derive`
**Costs you:** a UI or agent that treats `pending` as "nobody is working on it" is wrong for multi-target threads.

### Every write starts by locking the thread row, and lock order matters
Each writer starts with an `UPDATE … RETURNING` that bumps `lock_version`. That is the per-thread serialization on Postgres. On SQLite, every writer is already serialized. `release_claims!` and `expire_claims` lock their threads *before* touching messages, in thread-id order. The build notes say this order avoids inverting lock order against a concurrent post, which would deadlock on Postgres. · `lib/c3/threads.ex:lock_thread!` · `lib/c3/threads.ex:release_claims!` · `lib/c3/threads.ex:expire_claims`
**Costs you:** if you reorder these, or add a write that updates messages first, you get deadlocks that only show up on Postgres.

### A response without `reply_to` resolves everything you may answer
With no `reply_to`, a `response` resolves every pending request in the thread that is addressed to the author and not held by someone else. `reply_to` is filled in only when exactly one request was resolved. When nothing is resolvable, the response is still posted and resolves nothing. · `lib/c3/threads.ex:post_message` · `lib/c3/threads.ex:resolvable!` · `lib/c3/threads.ex:single`
**Costs you:** one bare "done" answers several requests at once, including `any` and `label:` requests you never claimed.

### `reply_to` pointing at a non-request resolves nothing, silently
If a response's `reply_to` points at a note or another response, it is accepted and resolves no request. There is no error. · `lib/c3/threads.ex:resolvable!`
**Costs you:** an agent that thinks it answered a request leaves the request open.

### You can answer without claiming
A response to an `open` request moves it straight to `done`, and sets `claimed_by_agent_id`/`claimed_at` to the responder. That is why `done` allows `claimed_by` to be set or blank. · `lib/c3/threads.ex:resolve!` · `lib/c3/threads/message.ex:validate_claimed_by`
**Costs you:** if you assume every `done` request went through a `request.claimed` event, your event counts come out wrong.

### `any` never includes its author, and a label needs no holder
`to: "any"` is addressed to everyone except the agent that wrote it. This holds for the inbox, for claiming and for answering. `label:x` is accepted even when no agent has that label. Naming yourself, or naming an agent that has left, is a `422`. A request to an agent that leaves *after* it was sent stays open forever; only `cancel` or a forced `finish` clears it. · `lib/c3/threads.ex:addressed_to` · `lib/c3/threads/targets.ex:check`
**Costs you:** threads that stay `pending` forever, waiting on a departed agent or an empty label.

### A claim conflict is a `409`, but "already mine" is a no-op
`claim` with no `request_id` takes every open request addressed to you. If you already hold every candidate, the call succeeds and returns them. It fails with `409` (with `claimed_by`) only when you hold nothing and claimed nothing. With an explicit `request_id`, a request addressed to someone else is a `403`, not a `409`. · `lib/c3/threads.ex:claim` · `lib/c3/threads.ex:actionable!`
**Costs you:** a client that retries on `409` and treats `403` as transient will loop.

### Cancel checks permission before state
A stranger cancelling an already-resolved request gets `403`, not `409`. Only the request's author or the thread's opener may cancel. Unlike post and claim, `cancel` does not check whether the thread is finished; on a finished thread, every request is already terminal, so cancel returns `409`. · `lib/c3/threads.ex:cancellable_request!`
**Costs you:** tests that expect `409` from the wrong actor fail.

### A finished thread rejects posts and claims, and `finish`/`reopen` repeat as no-ops
A post or claim on a finished thread is a `409` ("reopen it first"). Repeating `finish` or `reopen` returns `changed: false` rather than an error. A reopened thread always comes back as `answered`, because finishing left no pending request. `admin_finish` is always forced and records `cancelled_by: "admin"` with a `nil` actor. · `lib/c3/threads.ex:finish_thread` · `lib/c3/threads.ex:reopen` · `lib/c3/threads.ex:admin_finish`
**Costs you:** code that expects `reopen` to restore the old `pending` state is wrong; there is nothing left to wait on.

### Claim expiry needs both a stale claim and a silent agent
`expire_claims` releases a claim only when `claimed_at` is older than `claim_ttl` **and** the holder's `last_seen_at` is too, and only in open sessions. An agent that keeps polling keeps its claims indefinitely. · `lib/c3/threads.ex:expire_claims`
**Costs you:** you cannot use the TTL to time-box work.

### Message numbers are `max + 1` and are shared by every request of a post
A post to N targets inserts N requests, numbered consecutively from `next_message_number!`. Each one emits its own `message.posted`. Thread numbers come from a counter on the session, and a rolled-back open does not consume a number. · `lib/c3/threads.ex:insert_requests!` · `lib/c3/threads.ex:next_message_number!` · `lib/c3/threads.ex:next_thread_number!`
**Costs you:** the API returns `messages` as a list even for a single `to`; clients that read only the first entry miss the others.

### Ref parsing accepts more than one form
`reply_to`, `request_id` and `since` accept `"T3.2"`, `"2"` or the integer `2`, in any case, with whitespace trimmed. A ref to a different thread is a `422`, not a lookup elsewhere. · `lib/c3/threads.ex:parse_message_ref` · `lib/c3/threads.ex:parse_thread_ref`

### `GET /v1/inbox` has side effects
Reading the inbox marks the cancellations and alerts in it as seen, so each one appears only once. Claimed requests appear only for their holder. · `lib/c3_web/controllers/v1/inbox_controller.ex:show` · `lib/c3/threads.ex:inbox`
**Costs you:** a debug `curl` of `/v1/inbox` takes the cancellation notice away from the watcher. The cursor itself belongs to [sessions-and-agents](../sessions-and-agents/).

### Body size is checked twice
`check_body_size` returns `{:too_large, …}` (`413`) before the changeset runs. The changeset's byte limit would otherwise produce a `422`. A cancel `reason` goes through the same check. · `lib/c3/threads.ex:check_body_size` · `lib/c3/threads/message.ex:max_body_bytes`

## Known workarounds in the code

- **Conditional `UPDATE … WHERE request_state = 'open'`** in `lib/c3/threads.ex:claim` and `lib/c3/threads.ex:resolve!`, even though the thread row is already locked. SQLite has no per-row lock, and this guard is what guarantees exactly one winner in a race. The racing tests in `test/c3/threads/writes_test.exs` pin it.
- **`{1, _} =` match in `lib/c3/threads.ex:cancel`**: it crashes the transaction rather than emit `request.cancelled` for a row that did not change.
- **A forced finish emits one `request.cancelled` per pending request** (`reason: "thread finished"`) in `lib/c3/threads.ex:finish_thread`. Without it, the agent holding the claim was never told to stop; this was found and fixed in F8.
- **Tests are not `async`**: with async SQLite sandboxes, the write-lock queue exceeded the timeouts.

## Coverage

| Test | Pins |
|---|---|
| `test/c3/threads/derivation_test.exs` | the rule order of `derive` |
| `test/c3/threads/writes_test.exs` | open/post/claim/cancel/finish/reopen, both races (`any` claim; named request vs. its answer), leave recomputing status, claim expiry, inbox addressing |
| `test/c3/threads_test.exs` | changeset and CHECK invariants (`claimed_by` iff claimed, `finished_at` iff finished) |
| `test/c3_web/controllers/v1/thread_controller_test.exs` | HTTP status mapping of the context errors |

Gaps: the Postgres lock-order and deadlock behaviour is not exercised; the suite runs on SQLite only. A `reply_to` that points at a note in a response has no dedicated test.

## Prior tickets

| Ticket | What it changed | Watch out |
|---|---|---|
| `C3-1` (F3) | Threads, derived status, claims, cancel, `/inbox`; the per-session GenServer from the design was dropped in favour of the row lock | Do not reintroduce process-held state; the status cache relies on same-transaction recompute |
| `C3-1` (F8) | `admin_finish`; a forced finish now emits `request.cancelled` | Removing those events silently strands claim holders |
