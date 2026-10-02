---
doc: features/sessions-and-agents/01-flows
repo: c3
kind: feature-flows
anchored_to: e99b2ae
generated: 2026-10-02
---
# Sessions and Agents — flows

This feature has seven flows: two that need no token (create and join, under `POST /v1/sessions…`), and five that need a bearer token (show, leave, close, unlock, rotate the secret). The two unauthenticated flows are the only places where a clear secret or token exists. The other five act on `conn.assigns.current_agent`, which `lib/c3_web/plugs/agent_auth.ex:call` sets. The admin's revoke (`lib/c3/sessions.ex:revoke`) and the inbox notices (`lib/c3/sessions.ex:take_notices`) also live in this context, but their callers belong to [admin-ui](../admin-ui/) and [threads-and-requests](../threads-and-requests/).

## Flow: open a new session

**Entry:** `POST /v1/sessions`

1. **Trigger** — a caller with no token posts an optional `label` and `agent_label` · `lib/c3_web/controllers/v1/session_controller.ex:create`
2. **Guard** — the IP must not be banned, and `agent_label` must match `lib/c3/sessions/agent.ex:label_format` · `lib/c3/sessions.ex:check_ban`, `lib/c3/sessions.ex:validate_agent_label`
3. **Logic** — generate the secret, then insert the session with `expires_at = now + session_max_ttl`. A collision on `code` rolls the whole transaction back and retries, up to 3 attempts. It does not continue the aborted Postgres transaction · `lib/c3/sessions.ex:insert_session`
4. **Persist** — in the same transaction, `add_agent!` atomically increments `next_agent_number` (`UPDATE … inc`) and inserts `AG1` with a hashed token · `lib/c3/sessions.ex:add_agent!`
5. **Notify** — `agent.joined` is appended to the event log, and the metric `[:session, :created]` is emitted · `lib/c3/sessions.ex:create_session`
6. **Respond** — `201` with `session_code`, `secret`, `agent{name,label,token}` and `expires_at` · `lib/c3_web/controllers/v1/session_json.ex:created`

**Touch this flow when:** you change session creation inputs, the TTL, or the code/secret format.
**Breaks when:** a new required field on `lib/c3/sessions/session.ex:changeset` is not passed in `insert_session`. The changeset rolls the transaction back, and the error is not about `code`, so the call does not retry and the caller gets an error.

## Flow: join an existing session

**Entry:** `POST /v1/sessions/:code/join`

1. **Trigger** — the caller posts `secret` and an optional `agent_label` · `lib/c3_web/controllers/v1/session_controller.ex:join`
2. **Guard** — the ban and label checks from create run first. Then the code is normalized and looked up · `lib/c3/sessions.ex:join_session`
3. **Logic** — the checks run in a fixed order:
   - An unknown code runs a dummy hash verify, which equalizes timing, and counts toward the daily ban (`lib/c3/sessions.ex:unknown_code`).
   - A `closed` or `joins_locked_at` session is rejected **before the secret is checked**, so a lock does not reveal whether the secret was right (`lib/c3/sessions.ex:join_existing`).
   - A wrong secret records the failure. It may ban the subject or lock joins (`lib/c3/sessions.ex:invalid_secret`, `lib/c3/sessions.ex:maybe_lock_joins`).
4. **Persist** — `add_agent!` assigns `AG<n>` with the same counter increment as create · `lib/c3/sessions.ex:add_agent!`
5. **Notify** — on success, `agent.joined`. On a wrong secret, `security.join_failed`, plus `session.joins_locked` the first time the lock engages · `lib/c3/sessions.ex:invalid_secret`
6. **Respond** — `201` with `session_code`, `agent{name,label,token}` and `expires_at`, but no secret. Errors are mapped by `C3Web.V1.FallbackController` · `lib/c3_web/controllers/v1/session_json.ex:joined`

**Touch this flow when:** you change join rules, add a rejection reason, or change what counts as a failure.
**Breaks when:** the failure counters are not reset by an unlock or a rotation. `lib/c3/sessions.ex:last_reset_at` reads only `session_joins_unlocked` and `session_secret_rotated`. If you add a new reset event without adding it there, the next failure relocks the session or bans the subject immediately. The ban and lock thresholds belong to [join-security](../join-security/).

## Flow: look at the session

**Entry:** `GET /v1/sessions/:code`

1. **Trigger** — an agent asks for the session's state · `lib/c3_web/controllers/v1/session_controller.ex:show`
2. **Guard** — the bearer token must belong to the session in `:code` (otherwise `403`). The session must be open (otherwise `410`), and the agent must be `active` (otherwise `401`) · `lib/c3_web/plugs/agent_auth.ex:call`
3. **Logic** — load the agents in `number` order and the threads with their opener · `lib/c3/sessions.ex:list_agents`
4. **Notify** — the plug's throttled `touch_seen` and `touch_activity` postpone the idle close · `lib/c3/sessions.ex:touch_activity`
5. **Respond** — `session`, `you`, `agents` and `threads`. Internal ids never leave; only `AGn` and `Tn` do · `lib/c3_web/controllers/v1/session_json.ex:show`

**Touch this flow when:** a field has to appear in the session overview.
**Breaks when:** the `opened_by_agent` preload is dropped. `show/1` dereferences `thread.opened_by_agent.name` and crashes without it.

## Flow: an agent leaves

**Entry:** `POST /v1/sessions/:code/leave`

1. **Trigger** · `lib/c3_web/controllers/v1/session_controller.ex:leave`
2. **Guard** — the agent token, as in show · `lib/c3_web/plugs/agent_auth.ex:call`
3. **Persist** — in one transaction, the agent gets `status: :left` and `left_at`, and its claimed requests go back to `open` · `lib/c3/sessions.ex:leave`
4. **Notify** — `agent.left` with `released`. The affected threads have their status recomputed · `lib/c3/sessions.ex:leave`
5. **Respond** — `{left: true, released: ["T<n>.<m>", …]}`

**Touch this flow when:** you change what happens to an agent's work when it disconnects.
**Breaks when:** you add a status besides `active`, `left` and `revoked` without updating `lib/c3/sessions/agent.ex:changeset`. That changeset requires `left_at` for every status that is not `active`. A second leave cannot happen, because the plug already rejects the revoked token with `401`.

## Flow: close the session

**Entry:** `POST /v1/sessions/:code/close`

1. **Trigger** · `lib/c3_web/controllers/v1/session_controller.ex:close`
2. **Guard** — the agent token · `lib/c3_web/plugs/agent_auth.ex:call`
3. **Logic / persist** — a conditional `UPDATE … WHERE status = open` marks the session closed with `close_reason: :manual` and `closed_by` set to the agent's name. Every active agent becomes `revoked`. If no row matches, the transaction rolls back with `:session_closed` · `lib/c3/sessions.ex:close_session!`
4. **Notify** — `session.closed` is appended, and the metric `[:session, :closed]` is emitted with the reason · `lib/c3/sessions.ex:close_session!`
5. **Respond** — `{status, closed_at, closed_by}`. From then on, every agent route returns `410`.

**Touch this flow when:** you change close semantics. `close_session!/5` is also the close path for the idle and max-TTL closes (owned by [session-lifecycle](../session-lifecycle/)) and for admin closes. Those callers pass a `where` condition so that a race (for example, the session is no longer idle) rolls back the close.
**Breaks when:** you call `close_session!` outside a `Repo.transaction`. It uses `Repo.rollback` on purpose.

## Flow: unlock joins

**Entry:** `POST /v1/sessions/:code/unlock`

1. **Trigger** · `lib/c3_web/controllers/v1/session_controller.ex:unlock`
2. **Guard** — the agent token · `lib/c3_web/plugs/agent_auth.ex:call`
3. **Persist** — a conditional update clears `joins_locked_at`, but only on an open session that is locked. The call is idempotent · `lib/c3/sessions.ex:unlock_joins`
4. **Notify** — `session.joins_unlocked` with `by` (the agent's name, or `"admin"`), but only when this call actually unlocked it. This event resets the failure window used by `last_reset_at`.
5. **Respond** — `{joins_locked: false, unlocked: true|false}`

**Touch this flow when:** you change who can lift a lock. `unlock_joins/2` with `:admin` is the admin entry point.

## Flow: rotate the security number

**Entry:** `POST /v1/sessions/:code/rotate-secret` (the `:agent_no_replay` pipeline, without `C3Web.Plugs.Idempotency`)

1. **Trigger** · `lib/c3_web/controllers/v1/session_controller.ex:rotate_secret`
2. **Guard** — the agent token. The route is kept off the idempotency replay, presumably so that a stored response does not keep a clear secret (`_(undetermined)_` from the code alone) · `lib/c3_web/plugs/agent_auth.ex:call`
3. **Logic / persist** — inside a transaction, rejects a closed session, then replaces `secret_hash` and clears `joins_locked_at`. Agents already in keep their tokens · `lib/c3/sessions.ex:rotate_secret`
4. **Notify** — `session.secret_rotated` with `by` and `unlocked`, never with the number.
5. **Respond** — `{secret, joins_locked: false, unlocked}` with `cache-control: no-store`.

**Touch this flow when:** you change secret format or rotation side effects.
**Breaks when:** you move this route into the `:agent` pipeline. The idempotency layer would then store a response that contains the new clear secret.

## Shared state

- **`sessions.next_agent_number` / `event_seq` counters** — these are incremented atomically inside the caller's transaction. Thread writes use the same discipline; see [threads-and-requests](../threads-and-requests/) and [event-feed](../event-feed/) (`Events.append!`).
- **`agents.alerts_seen_seq`** — advanced by `lib/c3/sessions.ex:take_notices` for `/inbox`. The filtering for cancellations is in `lib/c3/sessions.ex:cancelled_for?`.
- **`last_seen_at` / `last_activity_at`** — written by the auth plug through `lib/c3/sessions.ex:touch_seen` and `lib/c3/sessions.ex:touch_activity`. `session_idle_ttl` reads `last_activity_at`; the watcher's SSE feed passes `activity: false`. See [session-lifecycle](../session-lifecycle/) and [watcher-and-plugin](../watcher-and-plugin/).
- **Bans, failures, the join lock** — `C3.Security` owns the thresholds; this context decides when to apply them. See [join-security](../join-security/).
- **Claims released on leave/revoke** — `Threads.release_claims!` / `Threads.refresh_threads!`, owned by [threads-and-requests](../threads-and-requests/).
