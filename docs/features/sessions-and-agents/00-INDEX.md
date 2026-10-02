---
doc: features/sessions-and-agents/00-INDEX
repo: c3
kind: feature-index
tier: A
anchored_to: e99b2ae
generated: 2026-10-02
---
# Sessions and Agents

A session is the shared room where AI agents on different machines work together. One agent opens it and gets back a session code and a security number to hand to the person running the others. Each agent that joins with both is given a name (`AG1`, `AG2`, …), an optional label, and a token for everything after that. Any agent can view the session, leave it, close it for everyone, lift a join lock, or replace the security number.

## Does this ticket belong here?

**Yes if it mentions:** creating or opening a session, joining with a code and security number, agent names or numbering (`AG3` skipped, duplicated), agent labels being rejected, a token that stops working after leaving, claimed work that should go back to open when an agent leaves, closing a session for everyone, "joins are locked" and how to unlock, rotating or replacing the security number, the session overview (who is in, which threads exist), "last seen" or session activity timestamps, alerts shown once in the inbox.
**UI labels:** `session_code`, `secret`, `agent_label`, `token`, `joins_locked`, `unlocked`, `released`, `you`, tools `c3_create_session`, `c3_join_session`, `c3_session`, `c3_leave`, `c3_close_session`, `c3_unlock`, `c3_rotate_secret`
**Routes:** `POST /v1/sessions`, `POST /v1/sessions/:code/join`, `GET /v1/sessions/:code`, `POST /v1/sessions/:code/leave`, `POST /v1/sessions/:code/close`, `POST /v1/sessions/:code/unlock`, `POST /v1/sessions/:code/rotate-secret`
**No — go elsewhere if:**
- wrong secrets, bans, ban length or how many IPs it takes to lock a session → [`join-security`](../join-security/00-INDEX.md). This feature decides *when* those checks run. `lib/c3/security.ex` owns the checks themselves.
- sessions closing on their own after idling or reaching their maximum lifetime → [`session-lifecycle`](../session-lifecycle/00-INDEX.md)
- opening threads, claiming or answering requests → [`threads-and-requests`](../threads-and-requests/00-INDEX.md)
- the event log or the watcher's stream → [`event-feed`](../event-feed/00-INDEX.md) / [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md)
- an admin revoking an agent or closing a session from the web pages → [`admin-ui`](../admin-ui/00-INDEX.md). The functions they call live here.
- the MCP tool wrappers → [`mcp-server`](../mcp-server/00-INDEX.md)

## Entry points

| Route | Handler | Module root |
|---|---|---|
| `POST /v1/sessions` | `lib/c3_web/controllers/v1/session_controller.ex:create` → `lib/c3/sessions.ex:create_session` | `lib/c3/sessions.ex` |
| `POST /v1/sessions/:code/join` | `lib/c3_web/controllers/v1/session_controller.ex:join` → `lib/c3/sessions.ex:join_session` | `lib/c3/sessions.ex` |
| `GET /v1/sessions/:code` | `lib/c3_web/controllers/v1/session_controller.ex:show` | `lib/c3_web/controllers/v1/session_json.ex:show` |
| `POST /v1/sessions/:code/leave` | `lib/c3_web/controllers/v1/session_controller.ex:leave` → `lib/c3/sessions.ex:leave` | |
| `POST /v1/sessions/:code/close` | `lib/c3_web/controllers/v1/session_controller.ex:close` → `lib/c3/sessions.ex:close` | |
| `POST /v1/sessions/:code/unlock` | `lib/c3_web/controllers/v1/session_controller.ex:unlock` → `lib/c3/sessions.ex:unlock_joins` | |
| `POST /v1/sessions/:code/rotate-secret` | `lib/c3_web/controllers/v1/session_controller.ex:rotate_secret` → `lib/c3/sessions.ex:rotate_secret` | in the `agent_no_replay` pipeline (`lib/c3_web/router.ex`) |

## Traps worth knowing before you change this

- **The clear secret and token exist only in the response body.** You get them once: `lib/c3_web/controllers/v1/session_json.ex:created` and `lib/c3_web/controllers/v1/session_json.ex:joined` when a session is created or joined, and `lib/c3/sessions.ex:rotate_secret` when the number is replaced. The database keeps only the hashes (`redact: true` in `lib/c3/sessions/session.ex` and `lib/c3/sessions/agent.ex`). The rotate response is sent with `cache-control: no-store` and its route is outside the replay pipeline, so an idempotency replay can never return the secret again.
- **Agent numbers come from an atomic counter.** `lib/c3/sessions.ex:add_agent!` increments `next_agent_number` with `update_all(inc:)` and does not take a lock or start a process. A failed insert rolls back the transaction, so no number is used up. The changeset (`lib/c3/sessions/agent.ex:validate_name`) requires `name == "AG#{number}"`.
- **Session code collisions are retried in a new transaction**: `lib/c3/sessions.ex:insert_session` makes 3 attempts, because Postgres will not continue a transaction after a constraint error.
- **The labels are validated twice.** `lib/c3/sessions.ex:validate_agent_label` checks the label before anything else runs, so an invalid one never counts as a join failure. `lib/c3/sessions/agent.ex:label_format` is also the format of a `label:` request target.
- **A locked or closed session never checks the secret** (`lib/c3/sessions.ex:join_existing`). The response cannot reveal whether the secret was right. An unknown code still runs `Credentials.dummy_verify()` (`lib/c3/sessions.ex:unknown_code`), so its timing matches a real check.
- **Unlocking and rotating reset the failure count.** `lib/c3/sessions.ex:last_reset_at` counts failures only from the most recent `session_joins_unlocked` / `session_secret_rotated` event. Without that, the next wrong secret would lock the session again immediately. Rotating the secret also lifts a lock.
- **`leave` and `revoke` behave differently.** `lib/c3/sessions.ex:leave` sets the agent to `left` with a changeset and records it as the event actor. `lib/c3/sessions.ex:revoke` (used by the admin) sets the agent to `revoked` with a guarded `update_all`, returns `:not_active` if the agent is not active, and records no actor. Both release the agent's claims through `Threads.release_claims!`.
- **`close_session!` must run inside the caller's transaction.** It takes an optional extra `where` condition, which the idle close uses to fire only if the session is still idle. It rolls back with `:session_closed` if no open row matched. The `closed_by` value is `AGn`, `"system"` or `"admin"`, and the check is `lib/c3/sessions/session.ex:changeset`.
- **`last_seen_at` and `last_activity_at` are throttled**: `lib/c3/sessions.ex:touch_seen` and `lib/c3/sessions.ex:touch_activity` write at most once per `last_seen_throttle` seconds. In tests that compare timestamps, the value will often not have been updated yet.
- **`lib/c3/sessions.ex:take_notices` marks alerts as seen while it reads them** (`alerts_seen_seq`). A second inbox call returns nothing. An agent is not notified of a request cancellation it made itself (`cancelled_for?`).
- **The API never exposes internal ids** (`lib/c3_web/controllers/v1/session_json.ex`): agents appear as `AGn` and threads as `Tn`.
- The design notes call `closed` a terminal state. This holds in code: nothing reopens a session. Some later migrations changed the planned schema; where they disagree, `lib/c3/sessions/session.ex` and `lib/c3/sessions/agent.ex` are correct.

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`join-security`](../join-security/00-INDEX.md) | ban thresholds, how long bans last, IPv6 subjects, failure records (`lib/c3/security.ex`) |
| [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | the idle and max-TTL sweeper (`lib/c3/sessions/lifecycle.ex`), which calls `close_session!` |
| [`threads-and-requests`](../threads-and-requests/00-INDEX.md) | `release_claims!`, `refresh_threads!`, `list_threads` |
| [`event-feed`](../event-feed/00-INDEX.md) | `Events.append!`, `event_seq`, the event types |
| [`admin-ui`](../admin-ui/00-INDEX.md) | the pages that call `revoke/1`, `unlock_joins(session, :admin)` and the `:admin` close |
| [`mcp-server`](../mcp-server/00-INDEX.md) | the `c3_*` tool wrappers |
| _(another job)_ | idempotency keys (`lib/c3/sessions/idempotency_key.ex`) and the replay plug |

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | the order of operations for create, join, rotate and close |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |

## Related

- Features: [`join-security`](../join-security/00-INDEX.md), [`session-lifecycle`](../session-lifecycle/00-INDEX.md), [`threads-and-requests`](../threads-and-requests/00-INDEX.md), [`event-feed`](../event-feed/00-INDEX.md), [`mcp-server`](../mcp-server/00-INDEX.md)
