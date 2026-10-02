---
doc: features/sessions-and-agents/02-files
repo: c3
kind: feature-files
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Sessions and Agents — files

The feature has one context module and two schemas in the domain layer, plus one thin controller and its JSON view. What surprises people is that `lib/c3/sessions.ex` does more than its name says. Session close (`close_session!/5`, which runs inside the caller's transaction), the join-failure path that bans IPs and locks joins, the `/inbox` notice cursor (`take_notices/1`) and the throttled liveness writes (`touch_seen/2`, `touch_activity/2`) all live there. The plug, the idle reaper, the admin pages and the MCP tools call into it. No session process exists: `lib/c3/sessions.ex:add_agent!` serializes counters with an atomic `UPDATE … inc` inside a transaction.

**Owned globs:** `lib/c3/sessions.ex`, `lib/c3/sessions/session.ex`, `lib/c3/sessions/agent.ex`, `lib/c3_web/controllers/v1/session_controller.ex`, `lib/c3_web/controllers/v1/session_json.ex`

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/sessions.ex` | `C3.Sessions.create_session/2` | context | Creates the session and `AG1` in one transaction. This is the only place the clear secret and token exist. | Changing what a new session gets (TTL, label rules), or the create response |
| `lib/c3/sessions.ex` | `insert_session` (private) | context | Retries up to 3 times on a `code` unique collision by rolling back the transaction. It never reuses a transaction after the constraint error. | Changing the code format or length in `lib/c3/credentials.ex` |
| `lib/c3/sessions.ex` | `C3.Sessions.join_session/3` | context | Checks the IP ban, then the label, then normalizes the code and dispatches to `join_existing`, `unknown_code` or `invalid_secret` | Adding a join error, or changing what a failed join records |
| `lib/c3/sessions.ex` | `join_existing` (private) | context | Checks in this order: closed, locked, secret. A locked session never verifies the secret, so it does not leak whether the secret was right. | Changing the join precedence |
| `lib/c3/sessions.ex` | `unknown_code` / `invalid_secret` / `maybe_lock_joins` (private) | context | Handles a failed join. `unknown_code` calls `Credentials.dummy_verify` for timing parity. A bad secret bans the IP and emits `security_join_failed`; enough distinct IPs set `joins_locked_at`. | Tuning lock or ban behaviour. Thresholds come from `lib/c3/config.ex`; ban storage is in [join-security](../join-security/02-files.md). |
| `lib/c3/sessions.ex` | `C3.Sessions.unlock_joins/1`, `unlock_joins/2` | context | Lifts the join lock. It is idempotent and returns `{:ok, false}` when the session was not locked. `by` is either an agent or `:admin`. | Changing who can unlock, or the unlock event payload |
| `lib/c3/sessions.ex` | `C3.Sessions.rotate_secret/1` | context | Sets a new secret hash and clears the lock. Existing tokens keep working. Failures from before the rotation stop counting toward the next lock, because `maybe_lock_joins` reads the last `session_secret_rotated` event. | Changing rotation semantics. The event must never carry the number. |
| `lib/c3/sessions.ex` | `C3.Sessions.leave/1` | context | Sets the agent to `left`, releases its claims and recomputes thread status, all in one transaction | Changing what leaving releases. Coordinate with `lib/c3/threads.ex:release_claims!`. |
| `lib/c3/sessions.ex` | `C3.Sessions.revoke/1` | context | Admin version of `leave`: ends in `revoked` with `by: "admin"`. Returns `{:error, :not_active}` when the agent is not active. | Changing admin revoke (UI side: [admin-ui](../admin-ui/02-files.md)) |
| `lib/c3/sessions.ex` | `C3.Sessions.close/1`, `close_session!/5` | context | Terminal close: revokes every active token and emits `session_closed`. `close_session!` must run inside the caller's transaction. Its `where` dynamic is how the idle reaper closes only if the session is still idle. | Adding a `close_reason`, or changing what close revokes. Callers: `lib/c3/sessions/lifecycle.ex`, `lib/c3/admin.ex`. |
| `lib/c3/sessions.ex` | `C3.Sessions.take_notices/1`, `cancelled_for?` (private) | context | Returns unseen security alerts plus the `request_cancelled` events relevant to this agent, and advances `alerts_seen_seq`. Reading has a side effect: each notice is returned once. | Changing which cancellations an agent hears about (`to`/`label:`/`any` rules). The caller is `lib/c3_web/controllers/v1/inbox_controller.ex`. |
| `lib/c3/sessions.ex` | `C3.Sessions.touch_seen/2`, `touch_activity/2` | context | Throttled writes to `last_seen_at` and `last_activity_at`. Both use the `last_seen_throttle` setting. | Changing presence or idle-close timing. They are called from `lib/c3_web/plugs/agent_auth.ex` and `lib/c3_web/controllers/v1/event_controller.ex`. |
| `lib/c3/sessions.ex` | `add_agent!` (private) | context | Takes the next `AG<n>` with an atomic increment, stores only the token hash, truncates `user_agent` to 500 chars, and emits `agent_joined` | Changing agent naming or what is recorded at join |
| `lib/c3/sessions.ex` | `C3.Sessions.get_agent_by_token/1`, `get_agent_by_token_hash/1` | context | Looks up the agent by token hash and preloads its session. It does **not** filter by status: callers check `active` themselves. | Changing the auth lookup. Callers: `lib/c3_web/plugs/agent_auth.ex`, `lib/c3_web/mcp/tools.ex`. |
| `lib/c3/sessions.ex` | `C3.Sessions.list_agents/1`, `get_session_by_code/1`, `get_idempotency_key/2` | context | Read helpers. Agents are listed in `number` order. | Adding a query |

## Schemas

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/sessions/session.ex` | `C3.Sessions.Session.changeset/2` | schema | Session row. It holds the counters `next_agent_number`, `next_thread_number` and `event_seq`. `closed_by` must match `AG<n>`, `system` or `admin`. `closed_at` is present if and only if the status is `closed`. | Adding a session column (plus a migration in `priv/repo/migrations`). Adding a `close_reason` value also needs the DB check constraint `sessions_close_reason_check`. |
| `lib/c3/sessions/agent.ex` | `C3.Sessions.Agent.changeset/2` | schema | Agent row. `name` must equal `"AG#{number}"`, `left_at` is present if and only if the agent is not `active`, and `token_hash` is unique. Rows are never deleted. | Adding an agent status or column |
| `lib/c3/sessions/agent.ex` | `C3.Sessions.Agent.label_format/0` | constant | `@label_format`: lowercase letters, digits and `-`, 1 to 40 chars. It also validates `label:` targets elsewhere. | Changing which labels are allowed. This affects request addressing too. |

## Controllers

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/controllers/v1/session_controller.ex` | `C3Web.V1.SessionController` (`create`, `join`, `show`, `leave`, `close`, `unlock`, `rotate_secret`) | controller | Thin layer over `C3.Sessions`. Errors go to `C3Web.V1.FallbackController`. `meta` builds the client IP from `conn.assigns.client_ip`. | Adding a session endpoint (route in `lib/c3_web/router.ex`) |
| `lib/c3_web/controllers/v1/session_controller.ex` | `rotate_secret` | controller | Sets `cache-control: no-store` because the response carries the new secret | Adding another response that contains a credential |
| `lib/c3_web/controllers/v1/session_json.ex` | `C3Web.V1.SessionJSON` (`created`, `joined`, `show`) | dto | Response shapes. Internal ids never appear: agents are shown as `AGn` and threads as `T<n>`. The token appears only in `created`/`joined`. | Changing the API response. The MCP tool output is separate: see [mcp-server](../mcp-server/02-files.md). |

## Tests

| Path | Covers |
|---|---|
| `test/c3/sessions_test.exs` | Context: create, join and its failures, leave, close, notices |
| `test/c3_web/controllers/v1/session_controller_test.exs` | HTTP contract of `/v1/sessions` |
| `test/c3_web/controllers/v1/f8_controller_test.exs` | `rotate-secret` and the other F8 endpoints _(scope beyond that undetermined)_ |
| `test/c3/db_constraints_test.exs` | DB check and unique constraints behind the schemas |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3/sessions/lifecycle.ex` | [session-lifecycle](../session-lifecycle/02-files.md) |
| `lib/c3/sessions/idempotency_key.ex`, `lib/c3_web/plugs/idempotency.ex` | [architecture · request pipeline](../../architecture/01-request-pipeline-and-routing.md) |
| `lib/c3/security.ex`, `lib/c3/security/` | [join-security](../join-security/02-files.md) |
| `lib/c3/credentials.ex` | [architecture · auth](../../architecture/03-authentication-and-authorization.md) |
| `lib/c3_web/plugs/agent_auth.ex` | [architecture · auth](../../architecture/03-authentication-and-authorization.md) |
| `lib/c3/events.ex`, `lib/c3_web/controllers/v1/event_controller.ex` | [event-feed](../event-feed/02-files.md) |
| `lib/c3/threads.ex` | [threads-and-requests](../threads-and-requests/02-files.md) |
| `lib/c3/admin.ex` | [admin-ui](../admin-ui/02-files.md) |
| `lib/c3_web/mcp/tools.ex` | [mcp-server](../mcp-server/02-files.md) |
