---
doc: features/sessions-and-agents/04-gotchas
repo: c3
kind: feature-gotchas
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Sessions and Agents — gotchas

## Non-obvious behaviour

### The clear secret and token exist in exactly one response
`create_session` hashes the secret before it inserts, and `add_agent!` hashes the token. Only the returned map carries the clear values, and only the `created` and `joined` views render them. Nothing can read them back later. · `lib/c3/sessions.ex:create_session` · `lib/c3/sessions.ex:add_agent!` · `lib/c3_web/controllers/v1/session_json.ex:created` · `lib/c3_web/controllers/v1/session_json.ex:joined`
**Costs you:** a client that drops the create or join response cannot recover its credentials. Any new endpoint that "shows the secret again" cannot be written without changing the storage model.

### `rotate-secret` must never be replayed from the idempotency store
The route uses the `:agent_no_replay` pipeline. If the response were stored, the new number would sit in clear text in the idempotency table for 24 h. Because nothing is stored, a client retry rotates the secret a second time and the first new number stops working. The response also sends `cache-control: no-store`. · `lib/c3_web/router.ex:agent_no_replay` · `lib/c3_web/controllers/v1/session_controller.ex:rotate_secret`
**Costs you:** moving the route into the normal agent pipeline leaks the secret into the database.

### A locked session never checks the secret
`join_existing` matches on `status: :closed` and `joins_locked_at` before it calls `Credentials.verify_secret`. If the secret were checked first, `403` versus `423` would reveal whether a guess was correct. Joins to a closed or locked session are recorded as failures but never ban the IP. · `lib/c3/sessions.ex:join_existing`
**Costs you:** reordering these clauses gives attackers a correctness oracle for the secret.

### Unknown and malformed codes are deliberately the same, and slow
If `Credentials.normalize_code` fails, the code is treated as unknown. `unknown_code` runs `Credentials.dummy_verify()` so its timing matches a real hash check. Unknown codes ban the IP only after the IP passes the daily `unknown_code_limit`. One wrong secret bans the IP immediately. · `lib/c3/sessions.ex:unknown_code` · `lib/c3/sessions.ex:invalid_secret`
**Costs you:** removing the dummy verify reveals which codes exist through timing.

### Only failures after the last unlock or rotation count toward a lock
`maybe_lock_joins` counts distinct IPs from the latest `session_joins_unlocked` or `session_secret_rotated` event, whichever is later. Without that cutoff, the first failure after an unlock would relock the session at once. `rotate_secret` also lifts the lock, because the lock protected the old number. · `lib/c3/sessions.ex:maybe_lock_joins` · `lib/c3/sessions.ex:rotate_secret`
**Costs you:** adding another "reset" action without adding its event type to that list makes the session relock immediately.

### Agent numbers come from a counter on the session row, not from `count(agents)`
`add_agent!` takes a number with an atomic `update_all(inc: [next_agent_number: 1])` and uses `next - 1`. No session process serializes joins. Agents are never deleted (`left` and `revoked` rows stay), so `AGn` names are never reused. The changeset rejects any name that is not `"AG#{number}"`. · `lib/c3/sessions.ex:add_agent!` · `lib/c3/sessions/agent.ex:validate_name`
**Costs you:** deriving the number from a row count breaks under concurrent joins, and a name chosen by the client fails validation.

### A code collision retries the whole transaction instead of continuing inside it
`insert_session` rolls back on a `code` unique-constraint error and tries again, up to 3 attempts. The retry happens outside the failed transaction because Postgres aborts a transaction after a constraint error. · `lib/c3/sessions.ex:insert_session`
**Costs you:** "simplifying" this into an in-transaction retry works on SQLite and breaks on Postgres.

### `leave` and `revoke` are similar but not interchangeable
`leave` sets `status: :left` through the changeset, with the agent as the event actor. `revoke` is admin-only: it does a guarded `update_all` on `status == :active` and returns `{:error, :not_active}` when the agent is no longer active. Its `agent.revoked` event has no actor and carries `by: "admin"`. Both release claims and refresh the affected threads in the same transaction. · `lib/c3/sessions.ex:leave` · `lib/c3/sessions.ex:revoke`
**Costs you:** watchers and the event feed react to the two event types differently (see `watcher-and-plugin`).

### `close_session!/5` must run inside the caller's transaction, and `closed_by` is constrained
It calls `Repo.rollback`, so calling it outside a transaction raises. The actor maps to `"system"` for `nil`, `"admin"` for `:admin`, or the agent's name, and `Session.changeset` only accepts `AGn|system|admin`. The optional `where` argument is how the idle sweep repeats its idle condition in the `UPDATE` itself (see `session-lifecycle`). · `lib/c3/sessions.ex:close_session!` · `lib/c3/sessions/session.ex:changeset`
**Costs you:** a new closer with any other `closed_by` value fails validation.

### `take_notices` is a read that writes
It moves `alerts_seen_seq` forward to the highest matching event, including cancellations it then filters out as irrelevant. `/inbox` therefore shows each notice once. Whether a cancellation is relevant is decided in Elixir from the `payload`, because querying JSON in SQL is not portable. Cancellations the agent made itself are skipped. · `lib/c3/sessions.ex:take_notices` · `lib/c3/sessions.ex:cancelled_for?`
**Costs you:** calling it from a status or diagnostic path silently consumes alerts.

### Presence and activity are both throttled
`touch_seen` and `touch_activity` write at most once per `last_seen_throttle` seconds, so the stored timestamps can be that far behind. `touch_activity` keeps the `last_activity_at < now` guard so it never moves the timestamp backwards. · `lib/c3/sessions.ex:touch_seen` · `lib/c3/sessions.ex:touch_activity`
**Costs you:** a test that expects a fresh timestamp right after a request fails.

### `agent_label` is validated before the code is looked up
An invalid label returns a changeset error (`422`) even for an unknown code, and it is not counted as a join failure. Labels must match `^[a-z0-9][a-z0-9-]{0,39}$`, the same format used for `label:` targets. · `lib/c3/sessions.ex:validate_agent_label` · `lib/c3/sessions/agent.ex:label_format`

### Internal ids never leave the API
The JSON views expose `AGn`, `Tn` and the session `code`, never row ids. `show` preloads `opened_by_agent` because the view reads `thread.opened_by_agent.name`. · `lib/c3_web/controllers/v1/session_json.ex:show` · `lib/c3_web/controllers/v1/session_controller.ex:show`
**Costs you:** removing the preload crashes `show` with an unloaded association.

## Known workarounds in the code

- **Every counter is an atomic `UPDATE … SET n = n + 1`, with no session `GenServer`.** This keeps the module stateless across nodes. The design relies on the Repo's immediate transaction mode outside tests. · `lib/c3/sessions.ex:add_agent!`
- **The `user_agent` is truncated to 500 characters** before insert. · `lib/c3/sessions.ex:add_agent!`
- **`unlock_joins/1` builds a bare `%Session{id: …}`** so it can share the admin path `unlock_joins/2`. The `status == :open` guard lives in the `UPDATE`, so unlocking a closed session returns `{:ok, false}`, not an error. · `lib/c3/sessions.ex:unlock_joins`

## Coverage

| Test | Pins |
|---|---|
| `test/c3/sessions_test.exs` | Domain behaviour of create, join, leave, close, the lock and rotation |
| `test/c3_web/controllers/v1/session_controller_test.exs` | HTTP status codes and JSON shapes of `/v1/sessions` |

_(undetermined)_: which individual cases these files cover. I did not open them.

## Prior tickets

| Ticket | What it changed | Watch out |
|---|---|---|
| `C3-1` (F2) | Sessions, credentials, bans, the join lock and the join order | The lock counts failures from the last unlock, because a relock-at-once bug was the alternative |
| `C3-1` (F3) | `leave` recomputes the status of the threads it released claims from | In F2 it released claims without recomputing thread status |
| `C3-1` (F7) | `revoke`, and `:admin` accepted as an actor in `close_session!` | `revoke` is not `leave`: it uses a different status and event |
| `C3-1` (F8) | `rotate_secret` and the `:agent_no_replay` pipeline | Never route rotation through idempotency replay |
