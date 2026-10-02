---
doc: features/sessions-and-agents/01-flows
repo: c3
kind: feature-flows
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Sessions and Agents — flows

This feature has seven flows, and they fall into two groups. Two of them are unauthenticated: **create** and **join**. They take credentials in and hand out clear credentials, and they run only through the `:v1` pipeline in `lib/c3_web/router.ex`. The other five act on the session of the token holder: **show**, **leave**, **close**, **unlock** and **rotate the secret**. They go through `AgentAuth` (`lib/c3_web/plugs/agent_auth.ex`), and every one except rotate also goes through the `Idempotency` plug. All seven are served by `lib/c3_web/controllers/v1/session_controller.ex` and backed by `lib/c3/sessions.ex`. The join's security branches (bans, the lock threshold) are only outlined here; [`join-security`](../join-security/) owns them.

## Flow: Open a new session

**Entry:** `POST /v1/sessions`

1. **Trigger** — The caller posts an optional `label` and `agent_label` · `lib/c3_web/controllers/v1/session_controller.ex:create`. The request metadata (`client_ip` and the `user-agent` header) comes from `lib/c3_web/controllers/v1/session_controller.ex:meta`.
2. **Guard** — A banned IP gets `{:error, :ip_banned, until}` before anything is written · `lib/c3/sessions.ex:check_ban`. A bad `agent_label` fails against `lib/c3/sessions/agent.ex:label_format` (`^[a-z0-9][a-z0-9-]{0,39}$`) · `lib/c3/sessions.ex:validate_agent_label`.
3. **Logic** — A secret is generated and hashed once. If the generated code collides, the whole transaction rolls back and is retried with a new code, up to 3 attempts. It is retried rather than reused because Postgres aborts a transaction after a constraint error · `lib/c3/sessions.ex:insert_session`.
4. **Persist** — The `Session` row is inserted with `expires_at = now + session_max_ttl`. `AG1` is created in the same transaction: `next_agent_number` is bumped with an atomic `UPDATE … inc` and the agent's number is `next - 1` · `lib/c3/sessions.ex:add_agent!`, `lib/c3/sessions/session.ex:changeset`.
5. **Notify** — `agent.joined` is appended to the event log · `lib/c3/sessions.ex:add_agent!`. The `[:session, :created]` metric is emitted · `lib/c3/sessions.ex:create_session`.
6. **Respond** — `201` with `session_code`, the clear `secret`, `agent` (`name`, `label`, `token`) and `expires_at` · `lib/c3_web/controllers/v1/session_json.ex:created`. **This is the only time the clear secret and token exist.** The database keeps only their hashes (`secret_hash` and `token_hash` are `redact: true`).

**Touch this flow when:** you add a session attribute set at creation, change the TTL, or change the shape of the code, secret or token (`C3.Credentials`).
**Breaks when:** the reverse proxy does not pass the client IP. `meta/1` reads `conn.assigns.client_ip`, which is set by `lib/c3_web/plugs/real_ip.ex`, and a wrong IP turns bans against the proxy itself. A retried create is **not** idempotent: this route is outside the `:agent` pipeline, so the `Idempotency` plug does not cover it, and a retry opens a second session.

## Flow: Join an existing session

**Entry:** `POST /v1/sessions/:code/join`

1. **Trigger** — The caller sends `secret` and an optional `agent_label` · `lib/c3_web/controllers/v1/session_controller.ex:join`.
2. **Guard** — The order is: ban check, then label check, then code normalization and lookup · `lib/c3/sessions.ex:join_session`. An unknown or malformed code calls `Credentials.dummy_verify()` so its timing matches a real secret check. It also counts toward the IP's daily limit and returns `:not_found` · `lib/c3/sessions.ex:unknown_code`.
3. **Logic** — `lib/c3/sessions.ex:join_existing` decides by clause order:
   - A `closed` session returns `:session_closed`.
   - A session with `joins_locked_at` set returns `:joins_locked` **without checking the secret**, so the response does not reveal whether the secret was right.
   - Otherwise the secret is verified.

   Both refusals are recorded and never lead to a ban.
4. **Persist** — On a valid secret, `lib/c3/sessions.ex:add_agent!` creates the next `AGn` in a transaction. On an invalid secret, `lib/c3/sessions.ex:invalid_secret` records the failure, bans the IP, appends `security.join_failed`, and may lock the session's joins (`lib/c3/sessions.ex:maybe_lock_joins`). That branch belongs to [`join-security`](../join-security/).
5. **Notify** — `agent.joined` on success. The ban is written to cache only after its transaction commits · `lib/c3/sessions.ex:invalid_secret` (`Security.cache_ban`).
6. **Respond** — `201` with `session_code`, `agent` (with the clear `token`) and `expires_at`. There is no secret in this response · `lib/c3_web/controllers/v1/session_json.ex:joined`. Errors are mapped to HTTP status codes in `C3Web.V1.FallbackController` · `lib/c3_web/controllers/v1/session_controller.ex:join` (`action_fallback`).

**Touch this flow when:** a join should return more data, labels change format, or a new refusal reason is added (add a `join_existing` clause **before** the secret check if it must not leak the secret's validity).
**Breaks when:** a client sends the code in a format that `Credentials.normalize_code` rejects. That case is reported as `:not_found` and counts toward a ban, not as a validation error.

## Flow: See the session (agents and threads)

**Entry:** `GET /v1/sessions/:code` (`:agent` pipeline)

1. **Trigger / guard** — `AgentAuth` puts `current_session` and `current_agent` in `conn.assigns` · `lib/c3_web/plugs/agent_auth.ex`. How it does that is _(see the auth document)_.
2. **Logic** — The handler loads the agents in join order (`lib/c3/sessions.ex:list_agents`, ordered by `number`) and the threads with their opener preloaded (`Threads.list_threads(…, preload: :opened_by_agent)`) · `lib/c3_web/controllers/v1/session_controller.ex:show`.
3. **Respond** — `lib/c3_web/controllers/v1/session_json.ex:show` returns:
   - `session`, with `joins_locked` derived as a boolean from `joins_locked_at`;
   - `you`, the caller's `AGn`;
   - every agent, **including those that have `left` or been `revoked`**, each with its `status`;
   - the threads, as `Tn`.

   Internal ids are never returned.

**Touch this flow when:** you add a field to the session or agent view (edit the private `session/1` and `agent/1` in `lib/c3_web/controllers/v1/session_json.ex`; `agent/2` is the variant that includes the token).
**Breaks when:** a thread has no `opened_by_agent` preloaded. `show/1` dereferences `.name` on it.

## Flow: An agent leaves

**Entry:** `POST /v1/sessions/:code/leave`

1. **Trigger** — `lib/c3_web/controllers/v1/session_controller.ex:leave`.
2. **Persist** — In one transaction, the agent is set to `status: :left` with a `left_at` · `lib/c3/sessions.ex:leave`. `lib/c3/sessions/agent.ex:changeset` requires `left_at` once the status is no longer `active`.
3. **Logic** — The agent's `claimed` requests go back to `open` (`Threads.release_claims!`), and the affected threads' status is recomputed in the same transaction (`Threads.refresh_threads!`). See [`threads-and-requests`](../threads-and-requests/).
4. **Notify** — `agent.left`, with the released `T<thread>.<message>` refs.
5. **Respond** — `{left: true, released: [...]}`.

**Touch this flow when:** leaving must also release something other than claims.
**Breaks when:** the update goes through `Agent.changeset` with no `active` guard, so a stale agent struct can be "left" again. The admin variant, `lib/c3/sessions.ex:revoke`, guards with `status == :active` and returns `:not_active` when the agent is not active. It ends the agent as `revoked`, not `left`, and emits `agent.revoked` with `by: "admin"`. It is used from [`admin-ui`](../admin-ui/).

## Flow: Close the session

**Entry:** `POST /v1/sessions/:code/close`

1. **Trigger** — `lib/c3_web/controllers/v1/session_controller.ex:close` calls `lib/c3/sessions.ex:close` with reason `:manual`.
2. **Guard** — The conditional `UPDATE … WHERE status = :open` (plus an optional `where` dynamic) rolls back with `:session_closed` when no row matches · `lib/c3/sessions.ex:close_session!`.
3. **Persist** — `status`, `closed_at`, `closed_by` (`AGn` / `system` / `admin`, enforced by `lib/c3/sessions/session.ex:changeset`) and `close_reason` are set. Every `active` agent is bulk-set to `revoked`.
4. **Notify** — The `[:session, :closed]` metric, then `session.closed`.
5. **Respond** — `{status, closed_at, closed_by}`. From this point every agent route of the session answers `410`.

**Touch this flow when:** you change what closing does. `close_session!/5` is shared with the idle and max-TTL sweeps of [`session-lifecycle`](../session-lifecycle/) and with the admin close. It must be called inside a transaction.
**Breaks when:** it is called outside `Repo.transaction`, because `Repo.rollback` raises. `closed` is terminal: nothing reopens a session.

## Flow: Lift the join lock

**Entry:** `POST /v1/sessions/:code/unlock`

1. **Trigger** — `lib/c3_web/controllers/v1/session_controller.ex:unlock`.
2. **Logic / persist** — A conditional update that only matches an `open` session that is locked. It is idempotent: `{:ok, false}` when the session was not locked · `lib/c3/sessions.ex:unlock_joins`. The admin form takes `:admin` as `by`.
3. **Notify** — `session.joins_unlocked` (`by`), only when this call did the unlocking. That event's timestamp resets the failure window used by `lib/c3/sessions.ex:maybe_lock_joins`, so old failures do not lock the session again straight away.
4. **Respond** — `{joins_locked: false, unlocked: bool}`.

**Touch this flow when:** the unlock rules change. Keep the event: the lock threshold depends on it.

## Flow: Rotate the security number

**Entry:** `POST /v1/sessions/:code/rotate-secret` (`:agent_no_replay` pipeline)

1. **Trigger** — `lib/c3_web/controllers/v1/session_controller.ex:rotate_secret`.
2. **Guard** — **No `Idempotency` plug.** A stored response would keep the new secret in clear for a day, so a retry simply rotates again · `lib/c3_web/router.ex:agent_no_replay`. A closed session rolls back with `:session_closed`.
3. **Persist** — A new `secret_hash` is stored and `joins_locked_at` is cleared in one transaction · `lib/c3/sessions.ex:rotate_secret`. Agents already in the session keep their tokens.
4. **Notify** — `session.secret_rotated`, with `by` and `unlocked` but never the number. It also resets the lock's failure window.
5. **Respond** — `{secret, joins_locked: false, unlocked}`, with `cache-control: no-store`.

**Touch this flow when:** another response starts carrying a secret. It needs the same no-replay pipeline and `no-store` header.

## Shared state

- **Counters on the session row.** `next_agent_number` (here), `next_thread_number` (owned by [`threads-and-requests`](../threads-and-requests/)) and `event_seq` (owned by [`event-feed`](../event-feed/)) are all bumped with atomic `UPDATE … inc`. There is no per-session process.
- **Throttled timestamps.** `last_seen_at` and `last_activity_at` are written by `lib/c3/sessions.ex:touch_seen` and `lib/c3/sessions.ex:touch_activity`, at most once per `last_seen_throttle`. Their callers are the auth plug and the feed. `last_activity_at` drives the idle close in [`session-lifecycle`](../session-lifecycle/).
- **Notices for `/inbox`.** `alerts_seen_seq` on the agent is advanced by `lib/c3/sessions.ex:take_notices`, which filters `request.cancelled` events per agent in `lib/c3/sessions.ex:cancelled_for?`. It is consumed by [`threads-and-requests`](../threads-and-requests/) and [`mcp-server`](../mcp-server/).
- **Security records.** Bans, failures and the join lock threshold are owned by [`join-security`](../join-security/) (`C3.Security`).
- **Idempotency.** Idempotency keys (`lib/c3/sessions.ex:get_idempotency_key`) are owned by the idempotency document.
- **Credentials.** Token lookup goes through `lib/c3/sessions.ex:get_agent_by_token`, which hashes the token and then finds the agent, with its session preloaded.
