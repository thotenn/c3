---
doc: features/sessions-and-agents/03-data
repo: c3
kind: feature-data
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Sessions and Agents — data

**Entry module:** `lib/c3/sessions.ex:C3.Sessions` · **Transport:** REST (`lib/c3_web/controllers/v1/session_controller.ex:C3Web.V1.SessionController`), and MCP through the same context (see `mcp-server`)

## Endpoints

All handlers sit in `lib/c3_web/controllers/v1/session_controller.ex`. Errors go through `action_fallback C3Web.V1.FallbackController`. The routes after `create`/`join` need a bearer token (`pipeline :agent`, see `join-security`).

| Operation | Method / name | Handler | Input | Output | Side effects |
|---|---|---|---|---|---|
| create session | `POST /v1/sessions` | `lib/c3_web/controllers/v1/session_controller.ex:create` | `"label"`, `"agent_label"` · `lib/c3/sessions.ex:create_session` | `201` · `lib/c3_web/controllers/v1/session_json.ex:created` (clear `secret` + `token`) | inserts session + `AG1`, emits `agent.joined`, metric `[:session, :created]` |
| join | `POST /v1/sessions/:code/join` | `lib/c3_web/controllers/v1/session_controller.ex:join` | `"secret"`, `"agent_label"` · `lib/c3/sessions.ex:join_session` | `201` · `lib/c3_web/controllers/v1/session_json.ex:joined` (clear `token`) | new agent + `agent.joined`; on failure records/bans/may lock (see `join-security`) |
| show | `GET /v1/sessions/:code` | `lib/c3_web/controllers/v1/session_controller.ex:show` | assigns from the auth plug | `lib/c3_web/controllers/v1/session_json.ex:show` | none beyond the auth plug's touches |
| leave | `POST /v1/sessions/:code/leave` | `lib/c3_web/controllers/v1/session_controller.ex:leave` | — · `lib/c3/sessions.ex:leave` | `%{left: true, released: [...]}` | agent → `left`, its claims back to `open`, threads recomputed, `agent.left` |
| close | `POST /v1/sessions/:code/close` | `lib/c3_web/controllers/v1/session_controller.ex:close` | — · `lib/c3/sessions.ex:close` | `status`, `closed_at`, `closed_by` | every active agent → `revoked`, `session.closed`, metric `[:session, :closed]` |
| unlock joins | `POST /v1/sessions/:code/unlock` | `lib/c3_web/controllers/v1/session_controller.ex:unlock` | — · `lib/c3/sessions.ex:unlock_joins` | `%{joins_locked: false, unlocked: bool}` | `session.joins_unlocked` only if it was locked |
| rotate secret | `POST /v1/sessions/:code/rotate-secret` | `lib/c3_web/controllers/v1/session_controller.ex:rotate_secret` | — · `lib/c3/sessions.ex:rotate_secret` | new clear `secret`, `cache-control: no-store` | new `secret_hash`, lock cleared, `session.secret_rotated` (never with the number) |

Traps:
- `rotate-secret` runs under `pipeline :agent_no_replay` in `lib/c3_web/router.ex`: no `Idempotency-Key` replay, so a cached response never holds the clear secret. A retry rotates again.
- The clear secret and token appear only in the return value of `create_session` / `join_session` / `rotate_secret`. Nothing stores them, so a lost secret means rotating it and a lost token means joining again.
- `show` lists every agent, including `left`/`revoked` ones (`lib/c3/sessions.ex:list_agents` does not filter on status), in `number` order.
- No internal id leaves the API. Agents are `AGn` and threads `Tn` (`lib/c3_web/controllers/v1/session_json.ex:show`).
- `join` with a wrong code returns `:not_found` and still runs `Credentials.dummy_verify()` (`lib/c3/sessions.ex:unknown_code`). That keeps an unknown code and a wrong secret indistinguishable by timing. A locked session never checks the secret (`lib/c3/sessions.ex:join_existing`).
- A banned IP gets refused by `create`/`join` (`lib/c3/sessions.ex:check_ban`). It does not stop a token it already holds (`lib/c3_web/plugs/agent_auth.ex:C3Web.Plugs.AgentAuth`).

Used outside the controller: `lib/c3/sessions.ex:take_notices` (by `/inbox`), `lib/c3/sessions.ex:revoke` and `unlock_joins(session, :admin)` (by `admin-ui`), and `lib/c3/sessions.ex:close_session!`. That last one runs inside the caller's transaction and takes an extra `where` condition, for idle/TTL closes (see `session-lifecycle`).

## Schema

| Entity | Table / type | Key fields | Constraints | Defined |
|---|---|---|---|---|
| Session | `sessions` | `code` (public), `secret_hash` (redacted), `status` `open\|closed`, `joins_locked_at`, `next_agent_number`, `next_thread_number`, `event_seq`, `last_activity_at`, `expires_at`, `closed_at`/`closed_by`/`close_reason` | unique `code`; `closed_at` present iff `closed`; `closed_by` matches `AGn\|system\|admin`; DB check constraints `sessions_status_check`, `sessions_closed_at_check`, `sessions_close_reason_check` | `lib/c3/sessions/session.ex:C3.Sessions.Session` |
| Agent | `agents` | `number`, `name` (`AG<number>`), `label`, `token_hash` (redacted), `status` `active\|left\|revoked`, `alerts_seen_seq`, `joined_ip`, `user_agent`, `last_seen_at`, `left_at` | unique `(session_id, number)`, `(session_id, name)`, `token_hash`; `name` must equal `"AG#{number}"`; `left_at` present iff not `active`; label `~r/^[a-z0-9][a-z0-9-]{0,39}$/` | `lib/c3/sessions/agent.ex:C3.Sessions.Agent` |

Stored vs derived:
- `joins_locked` in the JSON is derived from `joins_locked_at` (`lib/c3_web/controllers/v1/session_json.ex:session`). There is no boolean column.
- The agent's `name` is stored, but it is fully determined by `number`. Both come from the atomic `UPDATE … inc: [next_agent_number: 1]` in `lib/c3/sessions.ex:add_agent!`. Numbers are never reused, even after an agent leaves.
- `event_seq` and `next_thread_number` are counters on the session row. Other features own them (`event-feed`, `threads-and-requests`).
- Agents are never deleted. Leaving or revoking only changes `status` (`lib/c3/sessions/agent.ex:C3.Sessions.Agent`). `closed` is terminal for a session.
- `user_agent` is cut to 500 characters on insert (`lib/c3/sessions.ex:add_agent!`).
- On a `code` collision, session creation retries up to 3 times with a fresh transaction (`lib/c3/sessions.ex:insert_session`). It does not reuse the aborted one, because that would fail on Postgres.

## Cache, events and invalidation

Events are appended through `Events.append!` inside the same transaction as the write. The `event-feed` and `watcher-and-plugin` features consume them.

| Event | Emitted by | Notes |
|---|---|---|
| `agent_joined` | `lib/c3/sessions.ex:add_agent!` | for `AG1` too |
| `agent_left` / `agent_revoked` | `lib/c3/sessions.ex:leave` / `lib/c3/sessions.ex:revoke` | payload `released` = the `T<thread>.<message>` refs freed |
| `session_closed` | `lib/c3/sessions.ex:close_session!` | `closed_by`, `reason` |
| `security_join_failed`, `session_joins_locked` | `lib/c3/sessions.ex:invalid_secret`, `maybe_lock_joins` | shown once per agent by `take_notices` |
| `session_joins_unlocked`, `session_secret_rotated` | `lib/c3/sessions.ex:unlock_joins`, `rotate_secret` | reset the window for counting toward a new lock |

Cross-feature edges:
- **Leave/revoke changes threads.** `Threads.release_claims!` + `Threads.refresh_threads!` run in the same transaction (`lib/c3/sessions.ex:leave`), so thread statuses change without any thread call. See `threads-and-requests`.
- **The join-lock window.** `lib/c3/sessions.ex:maybe_lock_joins` counts distinct failing IPs since the later of the last `session_joins_unlocked` / `session_secret_rotated` event. Without that window, the next failure after an unlock would relock immediately. Deleting or renaming those events changes the lock behaviour.
- **Bans are cached in memory** with `Security.cache_ban` after the transaction commits. The `join-security` feature owns that cache.
- **`take_notices` keeps a cursor per agent.** It advances `alerts_seen_seq` to the last matching event, so each notice shows once. A notice read through one transport (REST `/inbox` or MCP) won't show again on the other. It leaves out cancellations the agent made itself (`lib/c3/sessions.ex:cancelled_for?`).
- **Closing revokes every token.** After that, `lib/c3_web/plugs/agent_auth.ex:C3Web.Plugs.AgentAuth` answers `410` for those tokens, not `401`.

## Scoping

- `create`/`join` are unauthenticated and scoped by the client IP (`conn.assigns.client_ip` in `lib/c3_web/controllers/v1/session_controller.ex:meta`). `join` also needs the `:code` from the path, normalized through `Credentials.normalize_code`.
- Every other route is scoped by the bearer token. `lib/c3_web/plugs/agent_auth.ex:C3Web.Plugs.AgentAuth` resolves the token to `current_agent` + `current_session`. The handlers never read `:code`, they use the assigns.
- Check order when the scope is missing or wrong:
  1. A missing or unknown token → `401`.
  2. A token from another session than `:code` → `403`.
  3. A closed session → `410`.
  4. An agent that left or was revoked → `401`.
- `unlock`/`rotate-secret` let any active agent of the session act on it. There is no owner role. `rotate_secret` rolls back with `:session_closed` if the session is closed.

## Local state

None. Each counter moves through an atomic `UPDATE` in a transaction, so no process is kept per session (`lib/c3/sessions.ex:C3.Sessions`). Two writes are throttled by `last_seen_throttle`:
- `last_seen_at`, through `lib/c3/sessions.ex:touch_seen`. It keeps claims alive.
- `last_activity_at`, through `lib/c3/sessions.ex:touch_activity`. It postpones the idle close.

The auth plug skips `touch_activity` on feed routes (`activity: false`). That way a watcher left running doesn't keep a forgotten session open.
