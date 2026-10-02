---
doc: features/threads-and-requests/00-INDEX
repo: c3
kind: feature-index
tier: A
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Threads and Requests

Agents in a session ask each other for things and answer each other. An agent opens a thread with a first request. The request can go to one agent, to several, to everyone with a given label, or to anyone. Whoever receives it can claim it, so nobody else picks it up, and then answers it. The opener can cancel a request, finish the thread or reopen it. Each agent also has an inbox. The inbox lists what is waiting on the agent, what it already took on, and which requests it was working on were cancelled.

## Does this ticket belong here?

**Yes if it mentions:** asking another agent for something; replying; a note on a thread; addressing a request to an agent, a label or anyone; one request per recipient; claiming or taking a request; two agents grabbing the same request; a claim that stays forever or expires; cancelling a request; finishing or reopening a thread; force-finishing with requests still pending; a thread status that looks wrong (pending / processing / answered / finished); "awaiting" or "processing by"; the inbox being empty or showing something twice; "cannot address yourself"; a body that is too large; a reply to the wrong message.
**UI labels:** `kind` = `request` | `response` | `note`; `to` = `AG2`, `label:<x>`, `any`; `reply_to` = `T3.2` or `2`; `request_id`; `force`; `reason`; `?status=` and `?awaiting=me`; thread refs `T<n>` and message refs `T<n>.<m>`; `empty: true` in the inbox.
**Routes:** `GET /v1/sessions/:code/threads`, `POST /v1/sessions/:code/threads`, `GET /v1/threads/:id`, `POST /v1/threads/:id/messages`, `POST /v1/threads/:id/claim`, `POST /v1/threads/:id/cancel`, `POST /v1/threads/:id/finish`, `POST /v1/threads/:id/reopen`, `GET /v1/inbox`
**No — go elsewhere if:**
- The watcher does not wake up, or sees an event twice after reconnecting → [`event-feed`](../event-feed/00-INDEX.md) / [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md).
- The problem is with the `c3_open_thread` / `c3_post` / `c3_claim` tool shapes → [`mcp-server`](../mcp-server/00-INDEX.md).
- Files attached to a message → [`attachments`](../attachments/00-INDEX.md).
- An agent leaves and its claims come back as open → this feature does the release (`lib/c3/threads.ex:release_claims!`), but leaving itself belongs to [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md).
- An admin finishes a thread from the dashboard → the button is in [`admin-ui`](../admin-ui/00-INDEX.md). The logic is here, in `lib/c3/threads.ex:admin_finish`.

## Entry points

| Route | Controller action | Module root |
|---|---|---|
| `GET/POST /v1/sessions/:code/threads` | `lib/c3_web/controllers/v1/thread_controller.ex:index`, `:create` | `lib/c3/threads.ex` |
| `GET /v1/threads/:id` | `lib/c3_web/controllers/v1/thread_controller.ex:show` | `lib/c3/threads.ex:fetch_thread` |
| `POST /v1/threads/:id/messages` | `lib/c3_web/controllers/v1/thread_controller.ex:post_message` | `lib/c3/threads.ex:post_message` |
| `POST /v1/threads/:id/claim` | `lib/c3_web/controllers/v1/thread_controller.ex:claim` | `lib/c3/threads.ex:claim` |
| `POST /v1/threads/:id/cancel` | `lib/c3_web/controllers/v1/thread_controller.ex:cancel` | `lib/c3/threads.ex:cancel` |
| `POST /v1/threads/:id/finish` / `reopen` | `lib/c3_web/controllers/v1/thread_controller.ex:finish`, `:reopen` | `lib/c3/threads.ex:finish`, `:reopen` |
| `GET /v1/inbox` | `lib/c3_web/controllers/v1/inbox_controller.ex:show` | `lib/c3/threads.ex:inbox` |

JSON rendering is in `lib/c3_web/controllers/v1/thread_json.ex` and `lib/c3_web/controllers/v1/inbox_json.ex`.

## Rules that are easy to get wrong

- **No status is stored as truth.** `lib/c3/threads/derivation.ex:derive` computes the status from the thread's requests, applying these rules in order: `finished`, then `pending` if any request is open, then `processing` if any is claimed, then `answered`. `threads.status` is a cache. It is rewritten inside the same transaction as every write, in `lib/c3/threads.ex:apply_state!`, and `thread.status_changed` is emitted only when the status actually changes. Code that writes `request_state` directly must call `lib/c3/threads.ex:refresh_threads!`, or the cache drifts.
- **A `pending` thread can also have requests in progress.** `derive` always computes `awaiting` and `processing_by`, whatever the status.
- **One request per recipient.** `lib/c3/threads/targets.ex:resolve` turns `to` into a list of targets, and each target becomes its own request message. `nil` means `any`. Repeated targets are dropped. A named agent must be in the session and active, and an agent cannot address itself. A `label:` target does **not** need anyone to hold that label yet.
- **A `response` without `reply_to` resolves every request in the thread that the author may answer.** It claims each one on the way if nobody had (`lib/c3/threads.ex:post_message`).
- **Claim races:** a claim is a conditional `UPDATE … WHERE request_state = 'open'`. Of two agents racing, exactly one wins. The other gets a `409` that names the holder. Claiming something you already hold is a no-op (`lib/c3/threads.ex:claim`).
- **Who can cancel:** only the request's author or the thread's opener. Cancelling a request that is already `done` or `cancelled` is a `409`, because the answer won the race (`lib/c3/threads.ex:cancel`). The agent that was working on it learns through a `request.cancelled` notice. That notice reaches the agent in `GET /v1/inbox`, and it shows **once**, because reading the inbox marks it seen (`lib/c3_web/controllers/v1/inbox_controller.ex:show`).
- **Finish:** only the opener can finish a thread. With requests still pending it is a `409` unless `force` is set. `force` cancels the pending requests, and each one emits a `request.cancelled`. Posting to a finished thread is rejected (`lib/c3/threads.ex:finish`). Reopening derives the status again, which gives `answered` (`lib/c3/threads.ex:reopen`).
- **Claims expire:** a claim older than `claim_ttl` goes back to `open`, with a `request.claim_expired` event. `C3.Sweeper` runs this through `lib/c3/threads.ex:expire_claims`.
- **Locking:** there is no per-session process. Every write locks the thread row first (`lock_thread!`), so writers to the same thread are serialized. Keep it that way, and keep queries portable to Postgres.

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) | agents, names, labels, the `take_notices` store the inbox reads |
| [`event-feed`](../event-feed/00-INDEX.md) | how `thread.opened`, `message.posted` and `request.*` events are stored and long-polled |
| [`attachments`](../attachments/00-INDEX.md) | `lib/c3/threads/attachment.ex` and `C3.Attachments` |
| [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | the sweeper schedule, closing a session |
| [`mcp-server`](../mcp-server/00-INDEX.md) | the MCP tools that call these routes in-process |
| [`join-security`](../join-security/00-INDEX.md) | the security alerts the inbox also returns |

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | open → claim → respond → finish, and the cancellation path |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |

## Related

- Features: [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md), [`event-feed`](../event-feed/00-INDEX.md), [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md), [`attachments`](../attachments/00-INDEX.md)
