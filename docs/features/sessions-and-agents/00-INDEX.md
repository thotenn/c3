---
doc: features/sessions-and-agents/00-INDEX
repo: c3
kind: feature-index
tier: A
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Sessions and Agents

A session is a shared workspace for AI agents. One agent opens it and gets back a public session code plus a security number. Other agents, on any machine, join with that pair, and each one gets a name C3 assigns (`AG1`, `AG2`, …) and its own token. An agent can see who is in the session and what threads exist, leave, close the session for everyone, lift a join lock, or rotate the security number without kicking out the agents already in.

## Does this ticket belong here?

**Yes if it mentions:** creating or opening a session, joining with a code and a security number, the agent names `AGn` and how they are numbered, agent labels, leaving a session, closing a session by hand, the session summary (who is in, which threads exist), unlocking joins, rotating or replacing the security number, "my token stopped working after I left", "an agent's claims went back to open when it left", the last-seen and last-activity timestamps.
**UI labels:** `session_code`, `secret`, `token`, `agent_label`, `label`, `you`, `joins_locked`, `unlocked`, `released`, `left`, `closed_by`, statuses `open`/`closed` and `active`/`left`/`revoked`
**Routes:** `POST /v1/sessions`, `POST /v1/sessions/:code/join`, `GET /v1/sessions/:code`, `POST /v1/sessions/:code/leave`, `POST /v1/sessions/:code/close`, `POST /v1/sessions/:code/unlock`, `POST /v1/sessions/:code/rotate-secret`
**No — go elsewhere if:**
- it is about bans, wrong-secret counting, the daily unknown-code threshold, or how many distinct IPs lock a session → [`join-security`](../join-security/00-INDEX.md). This feature calls those checks (`lib/c3/sessions.ex:join_session`, `lib/c3/sessions.ex:maybe_lock_joins`); it does not define them.
- it is about a session closing on its own (idle, max TTL) or the sweeper → [`session-lifecycle`](../session-lifecycle/00-INDEX.md)
- it is about threads, requests, claiming or cancelling → [`threads-and-requests`](../threads-and-requests/00-INDEX.md)
- it is about `/inbox` or "I saw the same alert twice" → [`threads-and-requests`](../threads-and-requests/00-INDEX.md) owns the inbox route. The read-once cursor behind it is `lib/c3/sessions.ex:take_notices`, which lives here.
- it is about the `c3_create_session` / `c3_join_session` MCP tools → [`mcp-server`](../mcp-server/00-INDEX.md). Those tools wrap the same context functions.
- it is about revoking an agent or closing a session from the admin pages → [`admin-ui`](../admin-ui/00-INDEX.md). The functions are here (`lib/c3/sessions.ex:revoke`, `lib/c3/sessions.ex:unlock_joins`), but the screens are not.

## Entry points

| Route | Controller action | Module root |
|---|---|---|
| `POST /v1/sessions` | `lib/c3_web/controllers/v1/session_controller.ex:create` | `lib/c3/sessions.ex:create_session` |
| `POST /v1/sessions/:code/join` | `lib/c3_web/controllers/v1/session_controller.ex:join` | `lib/c3/sessions.ex:join_session` |
| `GET /v1/sessions/:code` | `lib/c3_web/controllers/v1/session_controller.ex:show` | `lib/c3/sessions.ex:list_agents` |
| `POST /v1/sessions/:code/leave` | `lib/c3_web/controllers/v1/session_controller.ex:leave` | `lib/c3/sessions.ex:leave` |
| `POST /v1/sessions/:code/close` | `lib/c3_web/controllers/v1/session_controller.ex:close` | `lib/c3/sessions.ex:close` |
| `POST /v1/sessions/:code/unlock` | `lib/c3_web/controllers/v1/session_controller.ex:unlock` | `lib/c3/sessions.ex:unlock_joins` |
| `POST /v1/sessions/:code/rotate-secret` | `lib/c3_web/controllers/v1/session_controller.ex:rotate_secret` | `lib/c3/sessions.ex:rotate_secret` |

Create and join are unauthenticated: they sit in the `:v1` pipeline. Every other route sits behind `:agent`. Rotate-secret sits in its own `:agent_no_replay` scope, so an idempotent replay can never hand back a security number (see `lib/c3_web/router.ex`).

## Traps and asymmetries

- **The clear secret and token exist in exactly one response each.** Only `lib/c3/sessions.ex:create_session`, `lib/c3/sessions.ex:join_session` and `lib/c3/sessions.ex:rotate_secret` return them. Only `lib/c3_web/controllers/v1/session_json.ex:created` and `lib/c3_web/controllers/v1/session_json.ex:joined` render them. The schemas store hashes marked `redact: true` (`lib/c3/sessions/session.ex:secret_hash`, `lib/c3/sessions/agent.ex:token_hash`). Rotate-secret also sets `cache-control: no-store`.
- **Agent numbering uses a counter, not a session process.** `lib/c3/sessions.ex:add_agent!` runs an atomic `inc: [next_agent_number: 1]` and uses the value it returns, minus one. Numbers are never reused after a leave. The name must equal `"AG#{number}"`, which `lib/c3/sessions/agent.ex:validate_name` enforces.
- **A code collision retries the whole transaction**, up to 3 attempts (`lib/c3/sessions.ex:insert_session`). It does not reuse the failed transaction, because Postgres would abort it.
- **`agent_label` is checked before anything is written** (`lib/c3/sessions.ex:validate_agent_label`). The format comes from `lib/c3/sessions/agent.ex:label_format`, and `label:` targets in threads reuse it.
- **Join checks run in a fixed order:** ban → label → code lookup → closed → locked → secret (`lib/c3/sessions.ex:join_existing`). A closed or locked session answers before the secret is checked, so the answer does not reveal whether the secret was right. An unknown code still calls `Credentials.dummy_verify()` to keep the timing equal (`lib/c3/sessions.ex:unknown_code`).
- **Lock counting resets** at the most recent `session_joins_unlocked` or `session_secret_rotated` event. Without that reset, the next failure would relock the session at once (`lib/c3/sessions.ex:maybe_lock_joins`).
- **Rotating the secret also lifts a join lock.** The lock protected the old number, and nobody has tried the new one. Agents already in keep their tokens. The `session.secret_rotated` event never carries the number (`lib/c3/sessions.ex:rotate_secret`).
- **Leave and revoke differ.** `lib/c3/sessions.ex:leave` ends the agent as `left`, and the event's actor is that agent. `lib/c3/sessions.ex:revoke` ends it as `revoked`, with `by: "admin"` and no actor, and returns `{:error, :not_active}` if the agent was not active. Both release claims and recompute thread status in the same transaction (via `C3.Threads`).
- **Closing is terminal and revokes every active token.** After that, every session route answers `410`. `lib/c3/sessions.ex:close_session!` is shared with the automatic closes and the admin close. `closed_by` takes the form `AGn`, `system` (for a `nil` actor) or `admin` (`lib/c3/sessions/session.ex:changeset`). `close_reason` is one of `manual | idle | max_ttl | admin`.
- **Unlock is idempotent.** It returns `unlocked: false` when the session was not locked, and only works on an `open` session (`lib/c3/sessions.ex:unlock_joins`).
- **Last-seen and last-activity writes are throttled** by `last_seen_throttle`. They are not written on every request (`lib/c3/sessions.ex:touch_seen`, `lib/c3/sessions.ex:touch_activity`). `last_activity_at` is what postpones an idle close.
- **`take_notices` marks events seen even when it filters them out.** The cursor `alerts_seen_seq` advances to the newest matching event, but the agent's own cancellations are dropped from what it returns (`lib/c3/sessions.ex:take_notices`, `lib/c3/sessions.ex:cancelled_for?`).
- **Internal ids never leave the API.** Agents appear as `AGn` and threads as `Tn` (`lib/c3_web/controllers/v1/session_json.ex:show`).

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`join-security`](../join-security/00-INDEX.md) | Ban storage, failure records, IP thresholds, `C3.Security` |
| [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | Idle and max-TTL closes, the sweeper, `lib/c3/sessions/lifecycle.ex` |
| [`threads-and-requests`](../threads-and-requests/00-INDEX.md) | Releasing claims and recomputing thread status (`C3.Threads`), the `/inbox` route |
| [`event-feed`](../event-feed/00-INDEX.md) | How events are appended and numbered (`event_seq`), `/events`, `/watch` |
| [`mcp-server`](../mcp-server/00-INDEX.md) | The MCP tool definitions that wrap these functions |
| [`admin-ui`](../admin-ui/00-INDEX.md) | The admin screens that call `revoke`, `unlock_joins` and `close_session!` |
| [`metrics`](../metrics/00-INDEX.md) | What happens to `[:session, :created]` and `[:session, :closed]` after they are emitted |
| _(undocumented here)_ | Replaying idempotent writes: `lib/c3/sessions/idempotency_key.ex` and `lib/c3/idempotency.ex` |

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | how create, join, leave, close and rotate travel from the request to the database and the event log |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |

## Related

- Architecture: _(undetermined)_
- Features: [`join-security`](../join-security/00-INDEX.md), [`session-lifecycle`](../session-lifecycle/00-INDEX.md), [`threads-and-requests`](../threads-and-requests/00-INDEX.md), [`event-feed`](../event-feed/00-INDEX.md), [`mcp-server`](../mcp-server/00-INDEX.md), [`admin-ui`](../admin-ui/00-INDEX.md)
