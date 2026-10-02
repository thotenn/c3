---
doc: features/sessions-and-agents/02-files
repo: c3
kind: feature-files
anchored_to: e99b2ae
generated: 2026-10-02
---
# Sessions and Agents — files

Most of the feature's logic sits in one context module, `lib/c3/sessions.ex`. It owns more than its name suggests. Besides create, join, leave and close, it also holds the join-failure bookkeeping (`invalid_secret`, `unknown_code`, `maybe_lock_joins`), secret rotation, the admin `revoke/1`, the inbox's `take_notices/1`, and the throttled `touch_seen/2` and `touch_activity/2` that every authenticated request calls. People are often surprised that no process exists per session. Instead, every counter (`next_agent_number`, `event_seq`) moves through an atomic `UPDATE … inc` inside the caller's transaction (`lib/c3/sessions.ex:add_agent!`). People are also surprised that `close_session!/5` is a public function that must run inside someone else's `Repo.transaction`. The user close, the admin close and the idle/TTL sweeper all go through it.

**Owned globs:** `lib/c3/sessions.ex`, `lib/c3/sessions/session.ex`, `lib/c3/sessions/agent.ex`, `lib/c3_web/controllers/v1/session_controller.ex`, `lib/c3_web/controllers/v1/session_json.ex`

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/sessions.ex` | `C3.Sessions.join_session/3` | context | Checks the ban, then the code, then closed/locked, then the secret. After that it inserts the agent or records the failure. | Changing what a wrong secret, an unknown code or a locked session does, or the order of those checks. A locked session never verifies the secret (`join_existing`), so it does not leak whether the secret was correct. |
| `lib/c3/sessions.ex` | `C3.Sessions.create_session/2` | context | Creates the session and `AG1` in one transaction. If the code collides, it retries up to 3 times (`insert_session`). | Adding a field to session creation, or changing what the creator gets back. This is the only place the clear secret exists. |
| `lib/c3/sessions.ex` | `C3.Sessions.add_agent!` (private) | context | Takes the next agent number with `UPDATE … inc`, names the agent `AG<n>`, hashes its token, and emits `agent_joined`. | Changing how agents are numbered or named, or what goes in the join event. |
| `lib/c3/sessions.ex` | `C3.Sessions.leave/1`, `C3.Sessions.revoke/1` | context | Ends an agent (`left` / `revoked`), releases its claims through `C3.Threads.release_claims!`, and recomputes thread status. | Changing what happens to an agent's claimed requests when it goes. `revoke/1` is the admin's version: it is guarded by `status == :active` and returns `:not_active`. |
| `lib/c3/sessions.ex` | `C3.Sessions.close/1`, `C3.Sessions.close_session!/5` | context | Sets the session to `closed`, revokes every active token, and emits `session_closed`. It rolls back with `:session_closed` when the session was not open or when the extra `where` fails. | Adding a close reason, or changing what closing does to agents. The function has three callers (user, `lib/c3/admin.ex`, `lib/c3/sessions/lifecycle.ex`), so check all three. |
| `lib/c3/sessions.ex` | `C3.Sessions.unlock_joins/2`, `C3.Sessions.rotate_secret/1` | context | Lifts the join lock (as an agent or `:admin`). Replaces the secret hash, which also unlocks joins. | Changing how a locked session recovers. Both emit events that `last_reset_at` reads to reset the failure count. |
| `lib/c3/sessions.ex` | `C3.Sessions.invalid_secret`, `C3.Sessions.maybe_lock_joins` (private) | context | Records the failure, bans the subject past `secret_tolerance`, emits `security_join_failed`, and locks the session at `join_lock_ips` distinct subjects. | Tuning when a session locks. Thresholds and ban lengths live in `C3.Security` and are documented in [join-security](../join-security/). |
| `lib/c3/sessions.ex` | `C3.Sessions.take_notices/1` | context | Returns the security alerts and relevant `request_cancelled` events after `alerts_seen_seq`, and advances that cursor. | Changing what `/inbox` shows only once. The filter is `cancelled_for?`: the agent's own cancellations are excluded, and a cancellation counts if the request was addressed to `any`, to the agent's label, or to the agent's name. |
| `lib/c3/sessions.ex` | `C3.Sessions.touch_seen/2`, `C3.Sessions.touch_activity/2` | context | Updates `last_seen_at` / `last_activity_at` at most once per `last_seen_throttle`. | Changing presence, or what postpones the idle close. They are called from `lib/c3_web/plugs/agent_auth.ex`, and from the event stream (`lib/c3_web/controllers/v1/event_controller.ex`). |
| `lib/c3/sessions.ex` | `C3.Sessions.get_agent_by_token/1`, `C3.Sessions.list_agents/1`, `C3.Sessions.get_session_by_code/1` | context | Lookups. The token is hashed before the lookup and the session is preloaded. | Adding a lookup. `get_session_by_code/1` expects an already-normalized code (`Credentials.normalize_code` runs in `join_session/3`). |

## Schemas

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/sessions/session.ex` | `C3.Sessions.Session` | schema | The session row and its counters (`next_agent_number`, `next_thread_number`, `event_seq`). `secret_hash` is redacted. | Adding a session column (it also needs a migration and `@fields`), or a new `close_reason` value, which must match the DB check `sessions_close_reason_check`. |
| `lib/c3/sessions/session.ex` | `C3.Sessions.Session.changeset/2` | schema | `closed_at` must be present exactly when the status is `closed`. `closed_by` must match `AG<n>`, `system` or `admin`. | Allowing a new kind of closer. The regex and `close_session!/5` have to agree. |
| `lib/c3/sessions/agent.ex` | `C3.Sessions.Agent` | schema | An agent row. Agents are never deleted; `status` is `active`, `left` or `revoked`, and `left_at` is set once the agent is not active. | Adding an agent column or status. |
| `lib/c3/sessions/agent.ex` | `C3.Sessions.Agent.label_format/0` | schema | The label regex, `^[a-z0-9][a-z0-9-]{0,39}$`. It is shared by join validation and `label:` targets. | Changing which labels are allowed. That also changes which requests can be addressed (see [threads-and-requests](../threads-and-requests/)). |
| `lib/c3/sessions/agent.ex` | `C3.Sessions.Agent.changeset/2` (`validate_name`) | schema | Enforces `name == "AG#{number}"`. | Changing the naming scheme. It is enforced here and in `add_agent!`. |

## Controllers

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/controllers/v1/session_controller.ex` | `C3Web.V1.SessionController` | controller | Handles `/v1/sessions` create/join (unauthenticated) and show/leave/close/unlock/rotate-secret (as `current_agent`). Errors go to `C3Web.V1.FallbackController`. | Adding a session route, or changing a response code. `rotate_secret` sets `cache-control: no-store`. `meta/1` reads `client_ip` from the real-ip plug. |
| `lib/c3_web/controllers/v1/session_json.ex` | `C3Web.V1.SessionJSON` | dto | Wire shapes. Internal ids never appear: agents are `AGn` and threads `Tn`. The token appears only in `created` / `joined`. | Adding a field to the session, agent or thread summary in `GET /v1/sessions/:code`. |

## Tests

| Path | Covers |
|---|---|
| `test/c3/sessions_test.exs` | The context: create, join, failures, lock, leave, close, notices |
| `test/c3_web/controllers/v1/session_controller_test.exs` | The `/v1/sessions` HTTP contract |
| `test/c3/security/escalation_test.exs` | Escalating bans triggered by `invalid_secret` |
| `test/c3/db_constraints_test.exs` | The DB checks behind the `Session` / `Agent` changesets |
| `test/c3/sessions/lifecycle_test.exs` | Idle and TTL closes through `close_session!/5` |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3/sessions/lifecycle.ex` | [session-lifecycle](../session-lifecycle/) |
| `lib/c3/sessions/idempotency_key.ex` | [threads-and-requests](../threads-and-requests/) _(owner undetermined)_ |
| `lib/c3/security.ex`, `lib/c3/security/` | [join-security](../join-security/) |
| `lib/c3_web/plugs/agent_auth.ex` | [join-security](../join-security/) _(owner undetermined)_ |
| `lib/c3/threads.ex` (`release_claims!`, `refresh_threads!`) | [threads-and-requests](../threads-and-requests/) |
| `lib/c3/events.ex` | [event-feed](../event-feed/) |
| `lib/c3/admin.ex`, `lib/c3_web/live/admin/session_live.ex` | [admin-ui](../admin-ui/) |
| `lib/c3_web/controllers/v1/inbox_controller.ex` | [threads-and-requests](../threads-and-requests/) _(owner undetermined)_ |
