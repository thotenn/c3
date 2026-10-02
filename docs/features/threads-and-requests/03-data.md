---
doc: features/threads-and-requests/03-data
repo: c3
kind: feature-data
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Threads and Requests — data

**Entry module:** `lib/c3/threads.ex:C3.Threads` · **Transport:** REST (`lib/c3_web/controllers/v1/thread_controller.ex:C3Web.V1.ThreadController`, `lib/c3_web/controllers/v1/inbox_controller.ex:C3Web.V1.InboxController`). The MCP tools reach the same context functions; see `mcp-server`.

## Endpoints

All of these routes go through the `:agent` pipeline, so a bearer token is required (see `sessions-and-agents` / `join-security`). Errors come back as `{:error, reason}` from `lib/c3/threads.ex:C3.Threads`, and the shared fallback controller maps them: `:thread_not_found`, `{:invalid, …}` (422-style), `{:forbidden, …}`, `{:conflict, …}` (409), `{:too_large, …}` or a changeset.

| Operation | Method / name | Handler | Input | Output | Side effects |
|---|---|---|---|---|---|
| list threads | `GET /v1/sessions/:code/threads` | `lib/c3_web/controllers/v1/thread_controller.ex:index` | `status` (one of `@statuses`), `awaiting=me` only · `lib/c3_web/controllers/v1/thread_controller.ex:list_opts` | `lib/c3_web/controllers/v1/thread_json.ex:index` | — |
| open thread | `POST /v1/sessions/:code/threads` | `lib/c3_web/controllers/v1/thread_controller.ex:create` | `title`, `body`, `to`, `attachments` · `lib/c3/threads.ex:open_thread` | `201` · `lib/c3_web/controllers/v1/thread_json.ex:show` | one request per target; events `thread_opened` (+ `thread_status_changed` when the status moves) |
| read thread | `GET /v1/threads/:id` | `lib/c3_web/controllers/v1/thread_controller.ex:show` | `id` = `T3`; `since` = message ref · `lib/c3/threads.ex:parse_message_ref` | `lib/c3_web/controllers/v1/thread_json.ex:show` | — |
| post | `POST /v1/threads/:id/messages` | `lib/c3_web/controllers/v1/thread_controller.ex:post_message` | `kind`, `body`, `to` (requests only), `reply_to`, `attachments` · `lib/c3/threads.ex:post_message` | `201` · `lib/c3_web/controllers/v1/thread_json.ex:posted` (`thread`, `messages`, `resolved`) | a `response` sets requests to `done`; one `message_posted` per message created |
| claim | `POST /v1/threads/:id/claim` | `lib/c3_web/controllers/v1/thread_controller.ex:claim` | optional `request_id` · `lib/c3/threads.ex:claim` | `lib/c3_web/controllers/v1/thread_json.ex:action` + `claimed` | `request_claimed` per newly claimed request |
| cancel request | `POST /v1/threads/:id/cancel` | `lib/c3_web/controllers/v1/thread_controller.ex:cancel` | `request_id` (required), `reason` · `lib/c3/threads.ex:cancel` | `action` + `cancelled`, `note` | `request_cancelled`; when `reason` is given, also a `note` and `message_posted` |
| finish | `POST /v1/threads/:id/finish` | `lib/c3_web/controllers/v1/thread_controller.ex:finish` | `force` (`true` / `"true"`) · `lib/c3/threads.ex:finish` | `action` + `finished`, `cancelled` | with `force`, one `request_cancelled` per pending request (`reason: "thread finished"`) |
| reopen | `POST /v1/threads/:id/reopen` | `lib/c3_web/controllers/v1/thread_controller.ex:reopen` | — · `lib/c3/threads.ex:reopen` | `action` + `reopened` | status is derived again, normally to `answered` |
| inbox | `GET /v1/inbox` | `lib/c3_web/controllers/v1/inbox_controller.ex:show` | — · `lib/c3/threads.ex:inbox` | `lib/c3_web/controllers/v1/inbox_json.ex:show` | **this read has a side effect**: it marks cancellations and alerts as seen through `lib/c3/sessions.ex:take_notices` |

Contract details that cause bugs:
- **`post_message` returns `201` even for a `note`.** A `response` sent without `reply_to` resolves every request the author may answer (`lib/c3/threads.ex:resolvable!`). It skips requests claimed by someone else and claims open ones in the same step (`lib/c3/threads.ex:resolve!`). A `response` that replies to a non-request resolves nothing, and that is not an error.
- **Claim is idempotent for what you already hold.** It returns a 409 only when nothing was held and nothing got claimed, and that 409 includes `claimed_by` holders (`lib/c3/threads.ex:claim`).
- **Who can do what:**
  - Cancel: the request's author or the thread opener (`lib/c3/threads.ex:cancellable_request!`).
  - Finish and reopen: the opener only (`lib/c3/threads.ex:check_opened_by!`).
  - Admin finish is always forced and sets `cancelled_by: "admin"` (`lib/c3/threads.ex:admin_finish`).
- **Writes to a finished thread** (post or claim) return a 409 that says "reopen it first" (`lib/c3/threads.ex:rollback_finished`). Cancel does **not** check `finished_at`. That is harmless in practice, because finishing leaves no pending requests.
- **Target rules** (`lib/c3/threads/targets.ex:resolve`):
  - Leaving `to` out means `any`.
  - A named agent must be `active`, and nobody can address themselves.
  - A `label:` target needs no current holder.
  - Duplicate targets are dropped.
  - Names are matched case-insensitively and upper-cased.
- **`to` on a `response` or `note` is rejected** (`lib/c3/threads.ex:targets_for`).
- **Inbox JSON:** `empty: true` only when there are no threads, no cancellations and no alerts. Each request has `from` instead of `author`, and `kind` / `resolved_at` are dropped (`lib/c3_web/controllers/v1/inbox_json.ex:request`).

## Schema

| Entity | Table / type | Key fields | Constraints | Defined |
|---|---|---|---|---|
| Thread | `threads` | `number` (per session, readable as `T<n>`), `title` (1–200), `status`, `finished_at`, `last_message_at`, `lock_version`, `opened_by_agent_id` | unique `[session_id, number]`; `threads_status_check`; `threads_finished_at_check` (`finished_at` is set exactly when `status == :finished`) | `lib/c3/threads/thread.ex:C3.Threads.Thread` |
| Message | `messages` | `number` (per thread, `T<t>.<n>`), `kind` (`request`/`response`/`note`/`system`), `body`, `to_target`/`to_agent_id`/`to_label`, `request_state`, `claimed_by_agent_id`, `claimed_at`, `resolved_at`, `reply_to_message_id`, denormalized `session_id` | unique `[thread_id, number]`; check constraints `messages_*_check`; `to_target` and `request_state` only on requests; `claimed_by` set exactly when `claimed`, and either way when `done` (`lib/c3/threads/message.ex:validate_claimed_by`) | `lib/c3/threads/message.ex:C3.Threads.Message` |
| Derived state | none (pure map) | `status`, `awaiting`, `processing_by` | — | `lib/c3/threads/derivation.ex:derive` |

**Stored vs derived:**
- `threads.status` is **stored, but only as a cache** of `lib/c3/threads/derivation.ex:derive`. It is rewritten inside every write transaction by `lib/c3/threads.ex:apply_state!`.
- `awaiting` and `processing_by` are **never stored**. They are recomputed on every read by `lib/c3/threads.ex:states`, and `lib/c3_web/controllers/v1/thread_json.ex:summary` mixes the cached `status` with these live lists.
- **Do not add columns for `awaiting` or `processing_by`.** Anything that changes `request_state` outside `C3.Threads` must call `lib/c3/threads.ex:refresh_threads!`, or the stored status goes stale.

**Rules worth knowing:**
- **One request per target.** A request to `[AG2, AG3]` becomes two message rows with consecutive numbers that share the body and attachments (`lib/c3/threads.ex:insert_requests!`).
- **Derivation precedence:** `finished` > any `open` (→ `pending`) > any `claimed` (→ `processing`) > `answered`. A `pending` thread can therefore have a non-empty `processing_by`.
- **Numbering:**
  - Thread numbers come from `sessions.next_thread_number` (`lib/c3/threads.ex:next_thread_number!`).
  - Message numbers are `max + 1` computed under the thread lock (`lib/c3/threads.ex:next_message_number!`).
- **Message bodies are append-only.** Only the `request_*`, `claimed_*` and `resolved_at` columns change.
- **`kind: :system`** exists in the enum and is the only kind without an author. Nothing in this scope creates one.
- Attachment rows belong to `attachments`; this feature does not document them.

## Cache, events and invalidation

**The status cache and how a write runs:**
- Every write opens a transaction with `lib/c3/threads.ex:lock_thread!`, which runs `UPDATE … inc lock_version`. On Postgres this serializes the writers of one thread; SQLite already serializes all writers.
- The write then calls `lib/c3/threads.ex:apply_state!`, which:
  - writes `status` / `finished_at` only when they changed;
  - emits `thread_status_changed` (`from`, `to`, `awaiting`, `processing_by`, plus `cancelled` on finish) only when the status moved.

**Events appended through `C3.Events`** (consumed by the long-poll feed and the watcher; see `event-feed`, `watcher-and-plugin`):
- `thread_opened`
- `message_posted`: carries `resolved` and `resolved_for`, the requester names, so the watcher can wake the agent that asked.
- `request_claimed`
- `request_cancelled`: carries `claimed_by`, which is how a working agent learns to stop.
- `request_claim_expired`
- `thread_status_changed`

**Writers outside the HTTP surface that change request state and the status cache:**
- **Leaving a session** (`sessions-and-agents`). Claims go back to `open` via `lib/c3/threads.ex:release_claims!`, and the caller must then run `lib/c3/threads.ex:refresh_threads!`. The release itself emits no claim event.
- **Sweeper** (`session-lifecycle`). `lib/c3/threads.ex:expire_claims` re-opens claims whose agent's `last_seen_at` is older than `Config :claim_ttl`, but only in sessions with `status == :open`.
- **Admin UI** (`admin-ui`). `lib/c3/threads.ex:admin_finish`.

So a thread can move from `processing` back to `pending` without any agent posting to it.

**The inbox depends on events.** Cancellations and alerts in `/v1/inbox` come from the event log, not from `messages`, and reading them consumes them (`lib/c3/sessions.ex:take_notices`). A second call does not show them again.

## Scoping

**Session scope comes from the token.** The `:agent` pipeline assigns `current_session` and `current_agent`. On routes with `:code`, the token must belong to that session (`lib/c3_web/plugs/agent_auth.ex:same_session?`).

**Thread routes have no `:code`.** `T3` is resolved inside the token's session by `lib/c3/threads.ex:fetch_thread`. A `T3` that exists in another session, or a malformed ref, returns `:thread_not_found`, not a 403.

**Message refs** (`T3.5`, `"5"` or `5`) must belong to the thread in the URL. A ref to another thread returns `{:invalid, …}` (`lib/c3/threads.ex:parse_message_ref`).

**Addressing** (`lib/c3/threads.ex:addressed_to`) decides who sees a request. A request reaches an agent when it is:
- to that agent by name;
- to `any` and written by someone else (so `any` never reaches its own author);
- to `label:x` and the agent currently has label `x`.

An agent without a label never sees label requests. Its label at read time is what counts. This scope drives:
- `/v1/inbox` (open requests addressed to the agent, plus the ones it claimed);
- `awaiting=me`, which counts **only `open`** requests, so a thread whose request you claimed disappears from it;
- claim and implicit-response resolution.

## Local state

None. There is no per-session process. This differs from the private design spec, which planned a per-session GenServer. All coordination is the row lock plus conditional `UPDATE … WHERE request_state = 'open'` (`lib/c3/threads.ex:claim`), so a restart loses nothing.
