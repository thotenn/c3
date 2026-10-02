---
doc: features/sessions-and-agents/03-data
repo: c3
kind: feature-data
anchored_to: e99b2ae
generated: 2026-10-02
---
# Sessions and Agents — data

**Entry module:** `lib/c3/sessions.ex:C3.Sessions` · **Transport:** REST (`/v1`), and the MCP tools that dispatch into it in-process (see `mcp-server`)

## Endpoints

All routes are declared in `lib/c3_web/router.ex:C3Web.Router`. Errors are turned into responses by `C3Web.V1.FallbackController`, which this feature does not own.

| Operation | Method / name | Handler | Input | Output | Side effects |
|---|---|---|---|---|---|
| create session | `POST /v1/sessions` (pipeline `:v1`, no auth) | `lib/c3_web/controllers/v1/session_controller.ex:create` | `"label"`, `"agent_label"` · `lib/c3/sessions.ex:create_session` | `201` · `lib/c3_web/controllers/v1/session_json.ex:created`. The **only** response with the clear `secret`, plus `AG1`'s `token` | inserts session and `AG1`, emits `agent.joined` event, metric `[:session, :created]` |
| join | `POST /v1/sessions/:code/join` (no auth) | `lib/c3_web/controllers/v1/session_controller.ex:join` | `"secret"`, `"agent_label"` · `lib/c3/sessions.ex:join_session` | `201` · `lib/c3_web/controllers/v1/session_json.ex:joined` (token, no secret) | success: new agent plus `agent.joined`. Failure: security record, possible ban, `security.join_failed`, possible `session.joins_locked` (see `join-security`) |
| show | `GET /v1/sessions/:code` (`:agent`) | `lib/c3_web/controllers/v1/session_controller.ex:show` | bearer token | `lib/c3_web/controllers/v1/session_json.ex:show`: session, `you`, agents, thread summaries | none beyond the throttled touches made by auth |
| leave | `POST /v1/sessions/:code/leave` (`:agent`) | `lib/c3_web/controllers/v1/session_controller.ex:leave` | bearer | `{left: true, released: [...]}` | agent becomes `left`, its claims go back to `open`, threads recomputed, `agent.left` |
| close | `POST /v1/sessions/:code/close` (`:agent`) | `lib/c3_web/controllers/v1/session_controller.ex:close` | bearer | `{status, closed_at, closed_by}` | every active token is revoked, `session.closed`, metric `[:session, :closed]` |
| unlock joins | `POST /v1/sessions/:code/unlock` (`:agent`) | `lib/c3_web/controllers/v1/session_controller.ex:unlock` | bearer | `{joins_locked: false, unlocked: bool}` | `session.joins_unlocked`, only if a lock was actually lifted |
| rotate secret | `POST /v1/sessions/:code/rotate-secret` (`:agent_no_replay`) | `lib/c3_web/controllers/v1/session_controller.ex:rotate_secret` | bearer | `{secret, joins_locked: false, unlocked}` with `cache-control: no-store` | new `secret_hash`, lock cleared, `session.secret_rotated` (the payload never contains the number) |

Traps:
- `rotate-secret` uses the `agent_no_replay` pipeline on purpose. It skips `C3Web.Plugs.Idempotency`, because a stored reply would keep the new secret in clear (see the router comment above `pipeline :agent_no_replay`). A retry rotates the secret again.
- Every authenticated route under `:code` goes through `lib/c3_web/plugs/agent_auth.ex:C3Web.Plugs.AgentAuth`. A closed session answers `410` before the agent status is checked, so a token revoked by a close gets `410`, not `401`.
- The admin revoke path, `lib/c3/sessions.ex:revoke`, has no `/v1` route. Only the admin UI calls it (see `admin-ui`). It ends the agent as `revoked` and its event is `agent.revoked`, not `agent.left`.
- `lib/c3/sessions.ex:take_notices` feeds `GET /v1/inbox` (`lib/c3_web/controllers/v1/inbox_controller.ex`). It **marks the notices seen as it reads them**, so each notice is returned once. It skips the `request.cancelled` events the agent issued itself.

## Schema

| Entity | Table / type | Key fields | Constraints | Defined |
|---|---|---|---|---|
| Session | `sessions` | `code` (public), `secret_hash` (redacted), `status` `open\|closed`, `joins_locked_at`, counters `next_agent_number` / `next_thread_number` / `event_seq`, `last_activity_at`, `expires_at`, `closed_at` / `closed_by` / `close_reason` | unique `code`; `closed_at` present iff `closed`; `closed_by` matches `AGn\|system\|admin`; DB checks `sessions_status_check`, `sessions_closed_at_check`, `sessions_close_reason_check` | `lib/c3/sessions/session.ex:changeset` |
| Agent | `agents` | `number`, `name`, `label`, `token_hash` (redacted), `status` `active\|left\|revoked`, `alerts_seen_seq`, `joined_ip`, `user_agent`, `last_seen_at`, `left_at` | unique `(session_id, number)`, `(session_id, name)`, `token_hash`; `name` must equal `"AG#{number}"`; `left_at` present iff not active; `label` matches `lib/c3/sessions/agent.ex:label_format` | `lib/c3/sessions/agent.ex:changeset` |

Stored vs derived:
- `joins_locked` in JSON is **derived** from `joins_locked_at` being non-nil (`lib/c3_web/controllers/v1/session_json.ex:session`). It has no boolean column.
- Agent `name` is stored, but it is fully determined by `number`. The changeset rejects any other value.
- `number` comes from an atomic `UPDATE … inc: [next_agent_number: 1]` in `lib/c3/sessions.ex:add_agent!`. Never compute it with `max(number)+1`.
- `expires_at` is set once at creation from `Config.get(:session_max_ttl)`. Nothing in this scope extends it.
- Clear secrets and tokens are never stored. Only hashes are kept (`C3.Credentials`).
- `user_agent` is truncated to 500 chars at insert.
- Agents are never deleted. Leaving and revoking only change `status`.
- Internal ids never reach JSON. Agents are exposed as `AGn` and threads as `Tn` (`lib/c3_web/controllers/v1/session_json.ex`).

A code collision on create rolls the transaction back and retries, up to 3 attempts (`lib/c3/sessions.ex:insert_session`). It does not reuse the aborted transaction.

## Cache, events and invalidation

- **Events written** via `C3.Events.append!` (owned by `event-feed`), always inside the same transaction as the row change:
  - `agent.joined`, `agent.left`, `agent.revoked`
  - `session.closed`, `session.joins_locked`, `session.joins_unlocked`, `session.secret_rotated`
  - `security.join_failed`
- **Cross-feature writes:**
  - `leave` and `revoke` call `Threads.release_claims!` and `Threads.refresh_threads!` (`threads-and-requests`). Thread status changes from a session route.
  - `lib/c3/sessions.ex:close_session!` is public and runs inside the caller's transaction. The idle / max-TTL closer (`session-lifecycle`) and the admin both call it. Its `where` argument lets the caller re-check a condition on the row, such as "still idle", which avoids races.
- **Lock reset window:**
  - `lib/c3/sessions.ex:last_reset_at` takes the latest `session.joins_unlocked` or `session.secret_rotated` event. Only failures after it count toward a new lock or ban.
  - Unlocking or rotating therefore *invalidates* older failures. Deleting those events would re-arm the lock.
- **Ban cache:** after a failed join, `Security.cache_ban` updates the in-memory ban cache owned by `join-security`.
- **Throttled touches:**
  - `lib/c3/sessions.ex:touch_seen` and `lib/c3/sessions.ex:touch_activity` write at most once per `last_seen_throttle`, so a value read from the DB can lag by up to that interval.
  - `last_seen_at` keeps claims alive.
  - `last_activity_at` postpones the idle close. The `:feed` pipeline passes `activity: false`, so a watcher left running does not keep a session open.

## Scoping

- Unauthenticated routes are scoped by `:code`. It is normalized with `Credentials.normalize_code`; an invalid or unknown code takes the `unknown_code` path and counts toward the IP's daily limit.
- Authenticated routes are scoped by the bearer token, through `lib/c3_web/plugs/agent_auth.ex:C3Web.Plugs.AgentAuth`:
  - The token's session must match `:code`, or the request gets `403`.
  - With no token, or an unknown one: `401`.
  - Closed session: `410`.
  - Agent not active: `401`.
  - The IP ban is **not** checked for a live token.
- `show` lists every agent of the session, including the ones that left or were revoked, in `number` order (`lib/c3/sessions.ex:list_agents`).
- A locked session rejects a join **without verifying the secret**, so the response does not reveal whether the secret was right (`lib/c3/sessions.ex:join_session` doc).

## Local state

None. This feature holds no process and no ETS table: counters are atomic row updates. The only in-memory state it touches is the ban cache, which belongs to `join-security`.
