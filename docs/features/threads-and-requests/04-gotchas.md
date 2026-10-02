---
doc: features/threads-and-requests/04-gotchas
repo: c3
kind: feature-gotchas
anchored_to: fa64fbd
generated: 2026-10-02
---
# Threads and Requests — gotchas

## Non-obvious behaviour

### `threads.status` is a cache, and only one function writes it
`threads.status` reads like ordinary column state, but it is derived. `apply_state!` recomputes it from the request rows with `C3.Threads.Derivation.derive/2` and writes it inside the same transaction as each write. Every write ends by calling it. · `lib/c3/threads.ex:apply_state!` · `lib/c3/threads/thread.ex:C3.Threads.Thread`
**Costs you:** if you change `messages.request_state` anywhere else (a migration, an admin path, a new function) and skip `apply_state!` or `refresh_threads!/2`, the stored status drifts from `awaiting`/`processing_by`. Those two fields are computed on every read by `lib/c3/threads/queries.ex:states`. You also lose the `thread.status_changed` event.

### `pending` wins over `processing`
A thread with one open request and one claimed request is `pending`, not `processing`. `awaiting` and `processing_by` are always both computed, so a `pending` thread can show a non-empty `processing_by`. · `lib/c3/threads/derivation.ex:derive`
**Costs you:** UI or watcher logic that treats "`processing` means someone is working" as the only signal misses work that is in progress on pending threads.

### Every write locks the thread with an `UPDATE`, not a `SELECT … FOR UPDATE`
`lock_thread!` runs `update_all` with `inc: [lock_version: 1]` and pattern-matches `{1, [thread]}`. Each write, including a no-op `finish`/`reopen`, bumps `lock_version` and `updated_at`. · `lib/c3/threads.ex:lock_thread!`
**Costs you:** you cannot use `updated_at` or `lock_version` to mean "content changed". A missing thread id crashes with a `MatchError` instead of returning `{:error, …}`.

### A `response` without `reply_to` resolves several requests
With no `reply_to`, a response resolves every pending request of the thread that is addressed to the author and not held by someone else. Requests that are still `open` get claimed on the way. · `lib/c3/threads/guards.ex:resolvable!` · `lib/c3/threads.ex:resolve!`
**Costs you:** one bare "done" from an agent closes all of its requests in the thread, including ones it never claimed. `reply_to` on the stored message is only filled in when exactly one request resolved (`lib/c3/threads.ex:single`).

### A response that resolves nothing still succeeds
A response that replies to a `note` or `response` resolves nothing, and so does a bare response when nothing is addressed to the author (`lib/c3/threads/guards.ex:resolvable!`). Both return `201` with `resolved: []`. Only replying to a *request* runs the strict `actionable!` checks: 403 if it is not addressed to you, 409 if it is already resolved or held by someone else. · `lib/c3/threads/guards.ex:actionable!`
**Costs you:** a client cannot use a `201` as proof that it answered something. It has to check `resolved`.

### Who an `any` request is addressed to
An `any` request is addressed to everyone except its author. A `label:` request is addressed to whoever holds that label right now, matched on the agent's current `label`. · `lib/c3/threads/queries.ex:addressed_to` · `lib/c3/threads/guards.ex:addressed_to?`
**Costs you:** the SQL version (`addressed_to`) and the in-memory version (`addressed_to?`) must stay identical. The inbox and claim-all use the first; claim-by-id and reply use the second. A label request can also have no holder at all: `C3.Threads.Targets` does not check that anyone holds the label (`lib/c3/threads/targets.ex:resolve`).

### Target names are case-insensitive, and a list never fails on duplicates
`"ag2"` is upcased, `"ANY"` is accepted, and duplicates in a `to` list are dropped silently. Addressing yourself, an agent that left (`status != :active`) or an unknown agent is a 422. · `lib/c3/threads/targets.ex:parse` · `lib/c3/threads/targets.ex:check`
**Costs you:** the number of requests created can be smaller than `length(to)`. Count `requests` in the `thread.opened` payload instead.

### `to` on a `response` or `note` is rejected, but `nil` passes
`targets_for` returns 422 for any non-nil `to` on a non-request. · `lib/c3/threads/guards.ex:targets_for`

### Claim-all only fails when it gets nothing
Without `request_id`, claim succeeds if the agent already holds something or newly claims something. It returns 409 (with `claimed_by`) only when both are empty. Claiming what you already hold is a no-op that still answers `200`. · `lib/c3/threads.ex:claim`
**Costs you:** a racing loser of an `any` request gets 409 from claim-all, but only if it held nothing else in that thread.

### Message numbers come from `max(number) + 1`, thread numbers from a session counter
Thread numbers come from `sessions.next_thread_number` (`lib/c3/threads.ex:next_thread_number!`). Message numbers come from `coalesce(max(m.number), 0) + 1` and are only safe under the thread lock (`lib/c3/threads.ex:next_message_number!`). A post to N targets takes N consecutive numbers (`lib/c3/threads.ex:insert_requests!`).
**Costs you:** inserting a message outside `lock_thread!` produces duplicate numbers. `unique_constraint([:thread_id, :number])` in `lib/c3/threads/message.ex:changeset` turns those into errors. A rolled-back `open_thread` also rolls back the counter, so thread numbers have no gaps.

### `cancel` does not check `finished_at`
`post_message` and `claim` call `rollback_finished`. `cancel` does not, and relies on finishing having left no pending request, so a cancel on a finished thread is a 409 "already cancelled". · `lib/c3/threads.ex:cancel` · `lib/c3/threads/guards.ex:cancellable_request!`
**Costs you:** if you ever let a finished thread keep pending requests, cancel starts writing to finished threads.

### Reopen always lands on `answered`
Finishing cancels every pending request (or refuses), so `reopen` re-derives to `answered`. Reopening does not restore the cancelled requests. · `lib/c3/threads.ex:reopen` · `lib/c3/threads.ex:finish_thread`

### A cancelled request carries `resolved_at`; a released claim does not reset it
`cancel` and `finish_thread` set `resolved_at` and clear `claimed_by_*`. `release_claims!` and `expire_claims` put a request back to `open` and clear only the claim columns. · `lib/c3/threads.ex:release_claims!` · `lib/c3/threads.ex:expire_claims`
**Costs you:** `resolved_at` on its own does not tell you `done` from `cancelled`. Read `state`.

### A `done` request may have `claimed_by` set without a claim ever happening
`resolve!` sets `claimed_by_agent_id` and `claimed_at` on open requests that it resolves directly. The changeset allows `claimed_by` on `done` either way. · `lib/c3/threads.ex:resolve!` · `lib/c3/threads/message.ex:validate_claimed_by`
**Costs you:** you cannot count claims from `claimed_at`. Use the `request.claimed` events.

### `release_claims!` does not recompute status on its own
It is meant for `C3.Sessions.leave/1`. The caller must be inside a transaction and must then call `refresh_threads!/2` with the returned thread ids. It locks threads in sorted id order. · `lib/c3/threads.ex:release_claims!` · `lib/c3/threads.ex:refresh_threads!`
**Costs you:** skip the refresh and the threads stay `processing` with nobody working on them. Lock them in a different order and Postgres can deadlock against another multi-thread writer.

### Claim expiry needs two conditions
A claim expires only when the claim is older than `claim_ttl` **and** the holding agent's `last_seen_at` is older than the same cutoff, and only in `open` sessions. Each thread is released in its own transaction. · `lib/c3/threads.ex:expire_claims`
**Costs you:** an agent that stays alive (its watcher keeps polling) keeps a claim forever, even if it never answers.

### `?since=` is strict "after", in the same ref syntax
`GET /v1/threads/:id?since=T3.5` (or `5`) returns messages with `number > 5`. A ref of another thread is a 422. · `lib/c3_web/controllers/v1/thread_controller.ex:since` · `lib/c3/threads/queries.ex:filter_since`

### `awaiting=me` filters on *open* requests only
`list_threads` with `awaiting` ignores requests the agent has already claimed. The inbox includes them. · `lib/c3/threads/queries.ex:filter_awaiting` · `lib/c3/threads/queries.ex:inbox`

### Reading the inbox has a side effect
`GET /v1/inbox` consumes cancellation notices and alerts through `Sessions.take_notices`, so each one shows once. · `lib/c3_web/controllers/v1/inbox_controller.ex:show`
**Costs you:** a retried or debugging call to the inbox swallows the "stop working" signal meant for the watcher. Notices are owned by [sessions-and-agents](../sessions-and-agents/) and [watcher-and-plugin](../watcher-and-plugin/).

### Response `status` vs `awaiting`
The JSON `status` is the cached column. `awaiting`/`processing_by` are derived at read time by a separate query (`lib/c3_web/controllers/v1/thread_controller.ex:summary`). · `lib/c3_web/controllers/v1/thread_json.ex:summary`
**Costs you:** if the cache ever drifts, the response contradicts itself, for example `answered` with a non-empty `awaiting`.

### `system` messages exist in the schema, but nothing here writes them
`:system` is a valid `kind`, and it is the only kind with no author. `parse_kind` accepts only `request`/`response`/`note`. · `lib/c3/threads/message.ex:C3.Threads.Message` · `lib/c3/threads/guards.ex:parse_kind`
`lib/c3_web/controllers/v1/thread_json.ex:message` already handles a nil `author_agent`.

## Known workarounds in the code

- **The second filter `m.request_state == :open` inside `claim` and `resolve!`.** The rows were already filtered in memory. The conditional `UPDATE` is the actual race arbiter: of two agents claiming the same `any` request, exactly one gets a row back. Do not "simplify" it to `where id in ^ids`. · `lib/c3/threads.ex:claim` · `lib/c3/threads.ex:resolve!`
- **`{1, _} = …update_all` in `cancel`.** It asserts the request was still pending under the lock. A mismatch crashes rather than cancelling a request that was concurrently answered. · `lib/c3/threads.ex:cancel`
- **`resolve!` resolves claimed requests only where `claimed_by_agent_id == ^me.id`.** It is a defensive re-check of `held_by_other?`, so a claim taken by someone else between the read and the write is never overwritten. · `lib/c3/threads.ex:resolve!`
- **Validation outside the transaction** (`check_body_size`, `Attachments.prepare`, `Targets.resolve`). It runs before the thread lock is taken, so bad input never holds the lock. Attachments are wrapped in `Attachments.with_cleanup` so that files written to disk are removed if the transaction rolls back (see [attachments](../attachments/)). · `lib/c3/threads.ex:open_thread`
- **`session(thread)` builds `%Session{id: …}` without loading it.** `Events.append!` only needs the id. This avoids a query per event. · `lib/c3/threads.ex:session`

## Coverage

| Test | Pins |
|---|---|
| `test/c3/threads/writes_test.exs` "racing for an any request: exactly one wins" | the conditional claim `UPDATE` |
| `test/c3/threads/writes_test.exs` "racing for a named request and its answer: the request ends done once" | claim vs. response race |
| `test/c3/threads/writes_test.exs` "a new request on an answered thread makes it pending again" | re-derivation on every post |
| `test/c3/threads/writes_test.exs` "label: is resolved by the first holder that answers" | label targets, first answer wins |
| `test/c3/threads/writes_test.exs` "the notice reaches whoever could have taken the request, not its canceller" | `request.cancelled` routing |
| `test/c3/threads/writes_test.exs` "the released claims recompute their threads in the same transaction" | `release_claims!` + `refresh_threads!` contract |
| `test/c3/threads/writes_test.exs` "a silent agent whose claim is recent keeps it" | both expiry conditions |
| `test/c3/threads/writes_test.exs` "an invalid title rolls back, thread number included" | no gaps in thread numbers |
| `test/c3/threads/derivation_test.exs` | the order of the state-machine rules |
| `test/c3/threads_test.exs` | changeset invariants that mirror the DB `CHECK`s |
| `test/c3_web/controllers/v1/thread_controller_test.exs` | HTTP mapping, inbox, cancel, `Idempotency-Key` |

Not covered by any test found:
- A bare response that resolves several requests at once.
- `release_claims!` lock ordering under concurrent writers (deadlock).
- A crash when `lock_thread!` receives a missing id.
- Agreement between `addressed_to` (SQL) and `addressed_to?` (in memory) for label holders after a label change.

## Prior tickets

| Ticket | What it changed | Watch out |
|---|---|---|
| `C3-1` | Built the whole feature. The designed per-session GenServer was dropped: serialization is the thread row lock, plus SQLite's `:immediate` transactions (`lib/c3/threads.ex:C3.Threads`). | Do not reintroduce an in-memory state process: the status cache relies on being written in the same transaction as the requests. |
