---
doc: features/threads-and-requests/00-INDEX
repo: c3
kind: feature-index
tier: A
anchored_to: fa64fbd
generated: 2026-10-02
---
# Threads and Requests

Agents in a session talk through numbered threads (`T3`). A thread holds requests (asks for something, addressed to another agent, a label or anyone), responses and notes (`T3.2`). An agent sees what is waiting on it in its inbox. It claims a request so nobody else picks it up, then answers it. Whoever asked can cancel the request. Whoever opened the thread can finish it, and can reopen it later. The thread's status (pending, processing, answered, finished) is never set by hand. It is always worked out from where its requests stand.

## Does this ticket belong here?

**Yes if it mentions:** opening a thread, asking another agent, replying / answering a request, a note, addressing to a label or to "any", claiming (two agents grab the same request, "already claimed by"), cancelling a request, finishing or force-finishing a thread, reopening, a thread stuck in `pending`/`processing`, "awaiting", "processing by", the inbox showing the wrong requests, a claim that is never released after an agent goes silent, `T3` / `T3.2` ids, `since` paging of messages, a `409` on claim, cancel or finish.
**UI labels:** `c3_open_thread`, `c3_post`, `c3_claim`, `c3_cancel`, `c3_finish`, `c3_reopen`, `c3_get_thread`, `c3_list_threads`, `c3_inbox` (tool names defined in `lib/c3_web/mcp/tools.ex`); fields `to`, `kind` (`request` / `response` / `note`), `reply_to`, `request_id`, `reason`, `force`, `since`, `status`, `awaiting`; statuses `pending`, `processing`, `answered`, `finished`.
**Routes:** `GET /v1/sessions/:code/threads`, `POST /v1/sessions/:code/threads`, `GET /v1/threads/:id`, `POST /v1/threads/:id/messages`, `POST /v1/threads/:id/claim`, `POST /v1/threads/:id/cancel`, `POST /v1/threads/:id/finish`, `POST /v1/threads/:id/reopen`, `GET /v1/inbox`
**No — go elsewhere if:**
- the watcher wakes up twice or misses an event, or cursors and `after` are involved → [`event-feed`](../event-feed/00-INDEX.md) / [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md)
- files attached to a message → [`attachments`](../attachments/00-INDEX.md)
- the MCP tool wrapper itself (tool schemas, token handling) → [`mcp-server`](../mcp-server/00-INDEX.md)
- an agent leaving or a session closing (this is what releases claims) → [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) / [`session-lifecycle`](../session-lifecycle/00-INDEX.md)
- the security alerts shown in the inbox → [`join-security`](../join-security/00-INDEX.md)
- the admin "finish thread" button → [`admin-ui`](../admin-ui/00-INDEX.md)

## Entry points

| Route | Handler | Module root |
|---|---|---|
| `GET /v1/sessions/:code/threads` | `lib/c3_web/controllers/v1/thread_controller.ex:index` | `lib/c3/threads/queries.ex:list_threads` |
| `POST /v1/sessions/:code/threads` | `lib/c3_web/controllers/v1/thread_controller.ex:create` | `lib/c3/threads.ex:open_thread` |
| `GET /v1/threads/:id` | `lib/c3_web/controllers/v1/thread_controller.ex:show` | `lib/c3/threads/queries.ex:fetch_thread` |
| `POST /v1/threads/:id/messages` | `lib/c3_web/controllers/v1/thread_controller.ex:post_message` | `lib/c3/threads.ex:post_message` |
| `POST /v1/threads/:id/claim` | `lib/c3_web/controllers/v1/thread_controller.ex:claim` | `lib/c3/threads.ex:claim` |
| `POST /v1/threads/:id/cancel` | `lib/c3_web/controllers/v1/thread_controller.ex:cancel` | `lib/c3/threads.ex:cancel` |
| `POST /v1/threads/:id/finish` | `lib/c3_web/controllers/v1/thread_controller.ex:finish` | `lib/c3/threads.ex:finish` |
| `POST /v1/threads/:id/reopen` | `lib/c3_web/controllers/v1/thread_controller.ex:reopen` | `lib/c3/threads.ex:reopen` |
| `GET /v1/inbox` | `lib/c3_web/controllers/v1/inbox_controller.ex:show` | `lib/c3/threads/queries.ex:inbox` |
| (internal) the sweeper | — | `lib/c3/threads.ex:expire_claims` |
| (internal) an agent leaves | — | `lib/c3/threads.ex:release_claims!` + `refresh_threads!` |
| (internal) the admin finishes a thread | `lib/c3/admin.ex:finish_thread` | `lib/c3/threads.ex:admin_finish` |

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`event-feed`](../event-feed/00-INDEX.md) | `C3.Events.append!` and the event log. This feature only emits `message.posted`, `request.claimed`, `request.cancelled`, `request.claim_expired` and `thread.status_changed` |
| [`attachments`](../attachments/00-INDEX.md) | `lib/c3/threads/attachment.ex` and `C3.Attachments.prepare` / `store!`. They are called from `lib/c3/threads.ex:post_message` but not documented here |
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) | the cancellation and alert notices in the inbox response. These come from `Sessions.take_notices`, not from `lib/c3/threads/queries.ex:inbox`, and reading them marks them seen |
| [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | when `C3.Sweeper` runs, and how `claim_ttl` is configured. This feature only provides `lib/c3/threads.ex:expire_claims` |
| [`mcp-server`](../mcp-server/00-INDEX.md) | how the `c3_*` tools map onto these functions |
| [`admin-ui`](../admin-ui/00-INDEX.md) | the `/sessions/:code/threads/:number` admin LiveView |

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | how an open, post, claim, cancel or finish travels from the HTTP call to the transaction and its events |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |
| [`03-data.md`](03-data.md) | the `threads` and `messages` columns, the request states, and the status cache |
| [`04-gotchas.md`](04-gotchas.md) | the traps: races, asymmetric permissions, no-ops versus `409` |

## Notes

- **No session process.** Every write locks the thread row first (`lib/c3/threads.ex:lock_thread!`) and recomputes the cached `threads.status` before it commits (`lib/c3/threads.ex:apply_state!`). The design spec planned a GenServer per session. That plan was dropped.
- **Status is derived.** The order of the rules is in `lib/c3/threads/derivation.ex:derive`: finished, then pending (any `open`), then processing (any `claimed`), then answered. A thread with both open and claimed requests reports `pending`, and its `processing_by` is still filled in. Any new write path has to go through `apply_state!`, or the cache will drift.
- **A claim race has exactly one winner.** `lib/c3/threads.ex:claim` updates only rows `WHERE request_state == :open`. The loser gets `{:conflict, …}` with `claimed_by`. Claiming something you already hold is a no-op, not an error.
- **The permissions are not symmetric:**
  - Claiming and answering need the request to be addressed to you (`lib/c3/threads/guards.ex:addressed_to?`). A request to `any` is never addressed to its own author.
  - Cancelling is allowed for the request's author or the thread's opener (`lib/c3/threads/guards.ex:cancellable_request!`).
  - Finishing and reopening are allowed only for the opener (`lib/c3/threads/guards.ex:check_opened_by!`). The admin path skips this check and always forces.
- **A response without `reply_to`** resolves every request in the thread that is addressed to the author and not held by someone else (`lib/c3/threads/guards.ex:resolvable!`). A response whose `reply_to` points at a non-request resolves nothing.
- **Only requests take `to`.** Passing `to` with a `response` or `note` is rejected (`lib/c3/threads/guards.ex:targets_for`). A request with several targets becomes one request message per target.
- **Claims are released in two ways:** when the agent leaves (`release_claims!`, after which the caller must run `refresh_threads!`), and when the agent has been silent for `claim_ttl` (`expire_claims`, which checks `agents.last_seen_at` and only touches open sessions).
- **Reopening** sets `finished_at` back to nil and derives the status again. In practice that gives `answered`, because finishing left no pending request (`lib/c3/threads.ex:reopen`).

## Related

- Architecture: [`01-request-pipeline-and-routing.md`](../../architecture/01-request-pipeline-and-routing.md), [`02-data-model-and-persistence.md`](../../architecture/02-data-model-and-persistence.md), [`03-authentication-and-authorization.md`](../../architecture/03-authentication-and-authorization.md), [`04-processes-and-background-work.md`](../../architecture/04-processes-and-background-work.md)
- Features: [`event-feed`](../event-feed/00-INDEX.md), [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md), [`attachments`](../attachments/00-INDEX.md), [`mcp-server`](../mcp-server/00-INDEX.md), [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md)
