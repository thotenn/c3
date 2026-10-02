---
doc: features/threads-and-requests/02-files
repo: c3
kind: feature-files
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Threads and Requests — files

Almost all the logic lives in one context module, `lib/c3/threads.ex`. That module holds every read, every write, the claim/cancel/finish rules and the addressing query. The schemas are thin, and the controllers only translate HTTP. Two things surprise people. First, there is no per-session process: every write is a transaction that starts with `lib/c3/threads.ex:lock_thread!`, an `UPDATE` that bumps `lock_version`. Second, `threads.status` is a cache. Only `lib/c3/threads.ex:apply_state!` writes it, by re-running the pure `lib/c3/threads/derivation.ex:derive` inside that same transaction. The design spec planned a per-session GenServer, but it was not built. The MCP tools do not call this context directly. `lib/c3_web/mcp/dispatch.ex` replays them through `C3Web.Router`, so a change in `lib/c3_web/controllers/v1/thread_controller.ex` or `lib/c3_web/controllers/v1/thread_json.ex` also changes what MCP clients see.

**Owned globs:** `lib/c3/threads.ex`, `lib/c3/threads/thread.ex`, `lib/c3/threads/message.ex`, `lib/c3/threads/derivation.ex`, `lib/c3/threads/targets.ex`, `lib/c3_web/controllers/v1/thread_controller.ex`, `lib/c3_web/controllers/v1/thread_json.ex`, `lib/c3_web/controllers/v1/inbox_controller.ex`, `lib/c3_web/controllers/v1/inbox_json.ex`

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/threads.ex` | `C3.Threads.post_message/3` | context | inserts a request/response/note; a response resolves its `reply_to`, or with no `reply_to` every request the author may answer, claiming it on the way | changing what a response closes, adding a message kind, changing the `message.posted` payload (`resolved_for` is what wakes the requester's watcher) |
| `lib/c3/threads.ex` | `C3.Threads.claim/3` | context | conditional `UPDATE … WHERE request_state = 'open'`; already holding the request is a no-op, someone else holding it is a conflict that names them | changing race/conflict behaviour of claims, the `409` body (`claimed_by`) |
| `lib/c3/threads.ex` | `C3.Threads.cancel/3` | context | cancels one pending request (only its author or the thread opener can); an optional `reason` becomes a `note` replying to it | changing who may cancel, what the cancelled agent is told (`request.cancelled` payload) |
| `lib/c3/threads.ex` | `C3.Threads.finish/3`, `C3.Threads.admin_finish/1`, `C3.Threads.reopen/2` | context | finish fails with a conflict while requests are pending unless `force`, which cancels them; admin finishing is always forced with `cancelled_by: "admin"`; reopen re-derives the status | changing finish/force semantics, opener-only rules (`check_opened_by!`) |
| `lib/c3/threads.ex` | `C3.Threads.open_thread/2` | context | allocates `T<n>` from `sessions.next_thread_number`, inserts one request per target, emits `thread.opened` | changing what opening a thread creates or emits |
| `lib/c3/threads.ex` | `C3.Threads.inbox/1` | context | open requests addressed to the agent plus the ones it holds, grouped by thread | changing what counts as "to do" for an agent |
| `lib/c3/threads.ex` | `addressed_to` / `addressed_to?` | context | addressing rule, written twice: once as a query `dynamic` (inbox, `awaiting=me`, claim-all) and once in memory (single-request checks). Either way it means named agent, the agent's label, or `any` when not the author | changing addressing. **Edit both functions**, or the inbox and the claim/answer checks will disagree |
| `lib/c3/threads.ex` | `C3.Threads.apply_state!` (private), `C3.Threads.states/1`, `C3.Threads.state/1` | context | re-derives and writes the cached `status`/`finished_at`; emits `thread.status_changed` only when the status moved | any new write path. It must call `apply_state!` before committing, or the cache drifts |
| `lib/c3/threads.ex` | `C3.Threads.release_claims!/1`, `C3.Threads.refresh_threads!/2` | context | puts a leaving agent's claims back to `open`; the caller must run `refresh_threads!` in the same transaction | changing what leaving or being kicked does to held work (called from `lib/c3/sessions.ex`) |
| `lib/c3/threads.ex` | `C3.Threads.expire_claims/1` | context | reopens claims whose agent has been silent longer than `claim_ttl` (only in open sessions), with `request.claim_expired` | changing the claim TTL rule (run by `lib/c3/sweeper.ex`) |
| `lib/c3/threads.ex` | `C3.Threads.parse_thread_ref/1`, `C3.Threads.parse_message_ref/2`, `C3.Threads.thread_ref/1`, `C3.Threads.message_ref/2` | util | `T3` / `T3.5` / `5` parsing and formatting; a ref that points into another thread is rejected as invalid | changing id formats, which every JSON payload and event exposes |
| `lib/c3/threads/derivation.ex` | `C3.Threads.Derivation.derive/2` | service | pure state machine: `finished` › `pending` (any open) › `processing` (any claimed) › `answered`; `awaiting` and `processing_by` are always computed | changing thread status rules. A `pending` thread can also have a non-empty `processing_by` |
| `lib/c3/threads/targets.ex` | `C3.Threads.Targets.resolve/2`, `C3.Threads.Targets.display/3` | service | parses `to` (name, list, `label:<x>`, `any`; omitted means `any`) into one target per request; a named agent must be active and not the author, a label needs no current holder | adding a target kind, changing the "cannot address yourself" or inactive-agent errors |

## Schemas

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/threads/message.ex` | `C3.Threads.Message.changeset/2` | schema | a message; for requests, `to_*` and `request_state` must be present exactly; `claimed_by_agent_id` is required exactly when `claimed`, and either way on `done` | adding a column, a kind (`:system` already exists and has no author), or a request state; mirror it in the DB CHECKs under `priv/repo/migrations/` |
| `lib/c3/threads/message.ex` | `C3.Threads.Message.max_body_bytes/0` | constant | body cap, read from `C3.Config` `:max_body_bytes` | changing the body size limit (also checked before the transaction, in `check_body_size`) |
| `lib/c3/threads/thread.ex` | `C3.Threads.Thread.changeset/2` | schema | thread row; `finished_at` must be present iff `status == :finished` (also a DB CHECK); `lock_version` is the row-lock bump | adding a thread field, changing title limits (1–200) |

## Controllers

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/controllers/v1/thread_controller.ex` | `C3Web.V1.ThreadController` | controller | `/v1/sessions/:code/threads` and `/v1/threads/:id/{messages,claim,cancel,finish,reopen}`; resolves `T3` within the token's session; errors go through `C3Web.V1.FallbackController` | adding a thread endpoint or list filter (`status`, `awaiting=me` only) |
| `lib/c3_web/controllers/v1/inbox_controller.ex` | `C3Web.V1.InboxController.show/2` | controller | `GET /v1/inbox`: requests from `C3.Threads.inbox/1` plus notices from `C3.Sessions.take_notices/1`. **Reading it is a write**: it marks cancellations and alerts as seen, so each one shows only once | changing what the watcher wakes on |
| `lib/c3_web/controllers/v1/thread_json.ex` | `C3Web.V1.ThreadJSON.summary/2`, `C3Web.V1.ThreadJSON.message/2` | dto | only readable ids leave (`T3`, `T3.5`, `AG2`); request-only fields appear only on requests | changing the thread/message wire shape. Also reused by the inbox, the session view and MCP |
| `lib/c3_web/controllers/v1/inbox_json.ex` | `C3Web.V1.InboxJSON.show/1` | dto | `empty` flag, requests (with `from`, minus `kind`/`author`/`resolved_at`), cancellations taken from event payloads, alerts | changing the inbox shape that the plugin's watcher parses |

## Tests

| Path | Covers |
|---|---|
| `test/c3/threads/writes_test.exs` | open, responses (resolution with and without `reply_to`), claim races, cancel, finish/force/reopen, leave, `expire_claims/1`, `inbox/1`, `take_notices` |
| `test/c3/threads/derivation_test.exs` | rule order and the `awaiting`/`processing_by` lists of `derive/2` |
| `test/c3/threads_test.exs` | `Thread.changeset/2` and `Message.changeset/2` invariants against the DB CHECKs; context reads |
| `test/c3_web/controllers/v1/thread_controller_test.exs` | HTTP for threads, `GET /v1/inbox`, cancel, auth without `:code`, `Idempotency-Key` replay |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3/threads/attachment.ex`, `lib/c3/attachments.ex` | [`attachments`](../attachments/02-files.md) |
| `lib/c3/events.ex`, `lib/c3/events/event.ex` (the `Events.append!` calls made from here) | [`event-feed`](../event-feed/02-files.md) |
| `lib/c3/sessions.ex` (`take_notices`, `leave`/`kick` which call `release_claims!`) | [`sessions-and-agents`](../sessions-and-agents/02-files.md) |
| `lib/c3/sweeper.ex` | [architecture · processes](../../architecture/04-processes-and-background-work.md) |
| `lib/c3_web/plugs/idempotency.ex` | [architecture · request pipeline](../../architecture/01-request-pipeline-and-routing.md) |
| `lib/c3_web/mcp/dispatch.ex`, `lib/c3_web/mcp/tools.ex` | [`mcp-server`](../mcp-server/02-files.md) |
| `lib/c3/admin.ex` (`finish_thread` → `admin_finish/1`), `lib/c3_web/live/admin/session_live.ex` | [`admin-ui`](../admin-ui/02-files.md) |
| `plugin/` (the watcher that reads `/v1/inbox`) | [`watcher-and-plugin`](../watcher-and-plugin/02-files.md) |
