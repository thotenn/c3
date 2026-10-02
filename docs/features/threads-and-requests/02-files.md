---
doc: features/threads-and-requests/02-files
repo: c3
kind: feature-files
anchored_to: fa64fbd
generated: 2026-10-02
---
# Threads and Requests — files

This feature has one public context module, `lib/c3/threads.ex:C3.Threads`, and five helper modules behind it under `lib/c3/threads/`. Callers outside the context should only use `C3.Threads`. It covers reads by `defdelegate` to `lib/c3/threads/queries.ex:C3.Threads.Queries` and ref parsing by `defdelegate` to `lib/c3/threads/refs.ex:C3.Threads.Refs`. `lib/c3/threads/guards.ex:C3.Threads.Guards` says in its own moduledoc that it is "Internal to `C3.Threads`". All the writes (open, post, claim, cancel, finish, reopen, and claim release/expiry) are still in `threads.ex`. That is the one place where state changes happen.

Two things surprise people:

- **There is no session process.** A per-session GenServer was planned in the design, but it was dropped. The code serializes writers instead: every write opens a transaction whose first step is `lib/c3/threads.ex:lock_thread!`, an `UPDATE` that bumps `lock_version`. Inside that transaction, `lib/c3/threads.ex:apply_state!` recomputes `threads.status`. The column is a cache of `lib/c3/threads/derivation.ex:derive`.
- **The MCP server does not call `C3.Threads`.** `lib/c3_web/mcp/dispatch.ex` builds a conn and runs it through `Router.call`. Every MCP thread tool therefore goes through `lib/c3_web/controllers/v1/thread_controller.ex` and `lib/c3_web/controllers/v1/inbox_controller.ex`. If you change a controller or a JSON view, the MCP tool changes too. `test/c3_web/mcp/parity_test.exs` checks that the two stay in sync.

**Owned globs:** `lib/c3/threads.ex`, `lib/c3/threads/{thread,message,derivation,targets,refs,queries,guards}.ex`, `lib/c3_web/controllers/v1/thread_controller.ex`, `lib/c3_web/controllers/v1/thread_json.ex`, `lib/c3_web/controllers/v1/inbox_controller.ex`, `lib/c3_web/controllers/v1/inbox_json.ex`

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/threads.ex` | `C3.Threads.open_thread` | context | Creates the thread plus one request per target (shared attachments), emits `thread.opened` | changing what opening a thread does or emits |
| `lib/c3/threads.ex` | `C3.Threads.post_message` | context | Posts a request, response or note. A response resolves the requests it answers. Returns `%{thread, messages, resolved}` | a response should resolve more or fewer requests; posting to a finished thread |
| `lib/c3/threads.ex` | `C3.Threads.claim` / `C3.Threads.cancel` | context | A claim is a conditional `UPDATE … WHERE request_state = 'open'`, so the losing agent gets a `409` | race behaviour between two agents; who may cancel a request |
| `lib/c3/threads.ex` | `C3.Threads.finish` / `C3.Threads.reopen` / `C3.Threads.admin_finish` | context | Only `opened_by` may finish a thread. It must pass `force` while requests are pending. The admin path always forces (`finish_thread(thread, :admin, true)`) | changing who may close a thread |
| `lib/c3/threads.ex` | `C3.Threads.release_claims!` + `C3.Threads.refresh_threads!` | context | Puts an agent's claims back to `open` and does **not** recompute status itself. The caller (`lib/c3/sessions.ex`) has to call `refresh_threads!` in the same transaction | an agent leaves or is kicked and its claims misbehave |
| `lib/c3/threads.ex` | `C3.Threads.expire_claims` | context | Releases claims held by agents unseen for `claim_ttl`, emits `request.claim_expired`. Run by `lib/c3/sweeper.ex` | changing claim timeouts or what "silent agent" means |
| `lib/c3/threads.ex` | `apply_state!` | context | Writes the derived status and `finished_at` together (a CHECK ties them), emits `thread.status_changed` only when the status moved | a new state-changing write; extra event payload |
| `lib/c3/threads.ex` | `lock_thread!`, `next_thread_number!`, `next_message_number!` | context | Row lock, and the per-session `T<n>` and per-thread `.<n>` numbering | a write that skips the lock (don't); numbering gaps |

## State machine and helpers

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/threads/derivation.ex` | `C3.Threads.Derivation.derive` | util | Pure function with the precedence `finished` > `pending` (any open) > `processing` (any claimed) > `answered`. `awaiting` and `processing_by` are always computed, even when the thread is `pending` | adding a thread status or changing precedence |
| `lib/c3/threads/guards.ex` | `actionable!` | util | Rolls back with a reason when a request is not pending (409), not addressed to you (403) or held by someone else (409, with `claimed_by`) | changing an error code or message an agent sees |
| `lib/c3/threads/guards.ex` | `resolvable!` | util | A response without `reply_to` resolves **every** request addressed to the author that nobody else holds. A `reply_to` pointing at a non-request resolves none | "my response closed requests I didn't mean" |
| `lib/c3/threads/guards.ex` | `addressed_to?` | util | `agent` matches by id, `label` by label, `any` matches everyone except the author | changing who counts as a recipient |
| `lib/c3/threads/guards.ex` | `targets_for`, `parse_kind`, `check_body_size`, `check_reason` | util | Checks run before the transaction starts. `to` is rejected on anything but a request. `system` cannot be posted (it is not in `@kinds`) | accepting a new message kind or field |
| `lib/c3/threads/targets.ex` | `C3.Threads.Targets.resolve` | util | Turns `to` (name, list, `label:<x>`, `any`, or omitted = `any`) into targets and drops repeats. A named agent must be active and not the author. A label needs no current holder | adding an addressing form; self-addressing rules |
| `lib/c3/threads/targets.ex` | `C3.Threads.Targets.display` | util | Renders a target back as `AG2` / `label:x` / `any` | changing how `to` and `awaiting` read |
| `lib/c3/threads/refs.ex` | `thread_ref`, `message_ref`, `parse_thread_ref`, `parse_message_ref` | util | `T3` / `T3.2` readable ids. A message ref also accepts a bare positive integer | accepting a new ref syntax |

## Reads

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/threads/queries.ex` | `C3.Threads.Queries.inbox` | service | Open requests addressed to me plus the ones I claimed, grouped by thread in `[t.number, m.number]` order | changing what the watcher wakes for |
| `lib/c3/threads/queries.ex` | `list_threads` (`filter_status`, `filter_awaiting`) | service | Thread list with the `status` and `awaiting=me` filters | adding a list filter |
| `lib/c3/threads/queries.ex` | `states` / `state` / `request_rows` | service | Batch-derives state for display through `Derivation`. It is not the cached column | a list shows a wrong `awaiting` |
| `lib/c3/threads/queries.ex` | `fetch_thread`, `fetch_message`, `list_messages` (`since`) | service | Session-scoped lookup by ref, and incremental message reads | thread lookup crossing sessions; `?since=` |
| `lib/c3/threads/queries.ex` | `addressed_requests`, `addressed_to` | service | Query-side version of `Guards.addressed_to?`. The two must agree | changing addressing (change both) |

## Schemas

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/threads/message.ex` | `C3.Threads.Message.changeset` | schema | One row per message. Request-only fields (`to_target`, `request_state`) are enforced by `validate_present_iff` and mirrored by DB CHECKs (`messages_*_check`). `claimed_by` must be set exactly when `claimed`, and is optional when `done` | adding a message field or state; a CHECK violation in tests |
| `lib/c3/threads/message.ex` | `max_body_bytes` | schema | Body limit, counted in bytes, from `:max_body_bytes` | changing the body size limit |
| `lib/c3/threads/thread.ex` | `C3.Threads.Thread.changeset` | schema | `status` is a cache. `finished_at` must be present exactly when `finished` (`threads_finished_at_check`). Title is limited to 200 chars | adding a thread field; changing the title limit |

## Controllers

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/controllers/v1/thread_controller.ex` | `C3Web.V1.ThreadController` | controller | `/v1/sessions/:code/threads` and `/v1/threads/:id/{messages,claim,cancel,finish,reopen}`. `:id` is the `T3` ref inside the token's session. Errors go to `FallbackController` | adding a thread endpoint or query param (this changes MCP too) |
| `lib/c3_web/controllers/v1/thread_controller.ex` | `list_opts` / `status_opt` / `awaiting_opt` | controller | Validates `status` against `@statuses` and `awaiting` (only `"me"`) | new list filter |
| `lib/c3_web/controllers/v1/thread_json.ex` | `summary`, `message`, `posted`, `action` | dto | Wire shape of threads and messages. `posted` adds `resolved` | changing the response shape (breaks MCP parity) |
| `lib/c3_web/controllers/v1/inbox_controller.ex` | `C3Web.V1.InboxController.show` | controller | `GET /v1/inbox`. Calls `Sessions.take_notices`, which **marks cancellations and alerts as seen on read**, so each one is returned only once | inbox shows a notice twice or never |
| `lib/c3_web/controllers/v1/inbox_json.ex` | `C3Web.V1.InboxJSON.show` | dto | `empty: true` plus requests, cancellations and alerts | changing what the watcher parses |

## Tests

| Path | Covers |
|---|---|
| `test/c3/threads/derivation_test.exs` | Table of `derive` cases: precedence, `awaiting` and `processing_by` order and uniqueness |
| `test/c3/threads/writes_test.exs` | Write paths against the DB: events, claims, release/expiry |
| `test/c3/threads_test.exs` | Context API of `C3.Threads` |
| `test/c3_web/controllers/v1/thread_controller_test.exs` | REST endpoints, error codes, idempotency keys |
| `test/c3_web/mcp/parity_test.exs` | Same scenario through `/v1` and `/mcp`. Masked transcripts must be equal |
| `test/c3/db_constraints_test.exs` | DB CHECKs that back the changesets _(contents not read here)_ |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3/threads/attachment.ex`, `lib/c3/attachments.ex` | [attachments](../attachments/) |
| `lib/c3/sessions.ex` (calls `release_claims!` and `refresh_threads!`, `take_notices`) | [sessions-and-agents](../sessions-and-agents/) |
| `lib/c3/sweeper.ex` (calls `expire_claims`) | [session-lifecycle](../session-lifecycle/) |
| `lib/c3/events.ex` (`Events.append!`) | [event-feed](../event-feed/) |
| `lib/c3_web/mcp/dispatch.ex`, `lib/c3_web/mcp/tools.ex` | [mcp-server](../mcp-server/) |
| `lib/c3/admin.ex` (`finish_thread` → `admin_finish`), `lib/c3_web/live/admin/session_live.ex` | [admin-ui](../admin-ui/) |
| `lib/c3_web/plugs/agent_auth.ex`, `lib/c3_web/plugs/idempotency.ex`, `lib/c3_web/controllers/v1/fallback_controller.ex` | shared request pipeline |
