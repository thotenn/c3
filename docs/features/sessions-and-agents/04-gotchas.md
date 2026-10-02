---
doc: features/sessions-and-agents/04-gotchas
repo: c3
kind: feature-gotchas
anchored_to: e99b2ae
generated: 2026-10-02
---
# Sessions and Agents — gotchas

## Non-obvious behaviour

### The clear secret and token exist in exactly one response
Only the hashes are stored: `secret_hash` and `token_hash` are `redact: true`. The clear values come back only from `create_session`, `join_session` and `rotate_secret`. Only the rotate response sets `cache-control: no-store`. The `create` and `join` responses do not set it. · `lib/c3/sessions.ex:create_session` · `lib/c3/sessions.ex:rotate_secret` · `lib/c3_web/controllers/v1/session_controller.ex:rotate_secret` · `lib/c3_web/controllers/v1/session_json.ex:created`
**Costs you:** if a client loses the response, it has no way to get the credentials again. `GET` (`show`) never returns them. If you add caching to the create or join responses, the token can end up in a cache.

### The join checks run in a fixed order, and a locked session never checks the secret
`join_existing` checks in this order: closed, then locked, then the secret. A locked session returns `:joins_locked` without calling `Credentials.verify_secret`, so the response does not reveal whether the secret was right. Closed and locked attempts are recorded as failures but never lead to a ban. · `lib/c3/sessions.ex:join_existing`
**Costs you:** if you move the secret check earlier, someone attacking a locked session can confirm a guess.

### The secret tolerance uses `>`, the unknown-code limit uses `>=`
`invalid_secret` bans once `Security.secret_failures(...) > Config.get(:secret_tolerance)`. `unknown_code` bans once `unknown_codes_today(...) >= Config.get(:unknown_code_limit)`. · `lib/c3/sessions.ex:invalid_secret` · `lib/c3/sessions.ex:unknown_code`
**Costs you:** if you "unify" the two comparisons, one of the thresholds shifts by one attempt. The controller tests pin both thresholds.

### Failures before the last unlock or rotation do not count again
`last_reset_at` takes the latest `session_joins_unlocked` or `session_secret_rotated` event. Both the ban count and the distinct-IP lock count are measured from that point. · `lib/c3/sessions.ex:last_reset_at`
**Costs you:** if you drop the `since`, the next wrong secret after an unlock locks the session again (or bans) straight away.

### Rotating the secret also lifts the lock; unlocking does not change the secret
`rotate_secret` always writes `joins_locked_at: nil` and reports `unlocked`. `unlock_joins` clears the lock only while the session is `:open`, and it returns `{:ok, false}` when there was no lock. Agents already in the session keep their tokens after a rotation. · `lib/c3/sessions.ex:rotate_secret` · `lib/c3/sessions.ex:unlock_joins`
**Costs you:** if you expect the lock to stay in place after a rotation, you will be surprised. The design is that the lock protected the old number, and nobody has tried the new one yet.

### Agent names are never reused
`AG<n>` comes from an atomic `inc: [next_agent_number: 1]`, not from counting rows. An agent that leaves keeps its number. `Agent.changeset` rejects any `name` that is not `"AG#{number}"`. Labels are not unique: two agents in a session can have the same label. · `lib/c3/sessions.ex:add_agent!` · `lib/c3/sessions/agent.ex:validate_name`
**Costs you:** code that derives `n` from `length(list_agents(...))` will produce a name that already exists.

### Leaving, revoking and closing end in different agent statuses
- `leave` sets the agent to `:left`.
- `revoke` sets it to `:revoked`, guarded by `status == :active`.
- `close_session!` sets every active agent to `:revoked`.

Revoking an agent in a closed session therefore returns `{:error, :not_active}`. `leave` itself has no `:active` guard; whether the auth plug blocks a second leave is _(undetermined)_ from these files. · `lib/c3/sessions.ex:leave` · `lib/c3/sessions.ex:revoke` · `lib/c3/sessions.ex:close_session!`
**Costs you:** filtering on `:left` misses agents whose session was closed.

### `close_session!` must run inside the caller's transaction
`close_session!` calls `Repo.rollback(:session_closed)`, which only works inside a transaction. The optional `where` is an extra condition on the session row: the lifecycle job uses it to close only if the session is still idle. When that condition fails, it looks to the caller like `:session_closed`. · `lib/c3/sessions.ex:close_session!`
**Costs you:** if you call it outside `Repo.transaction`, it raises.

### `take_notices` marks everything up to the last event as seen, even events it filters out
`take_notices` moves `alerts_seen_seq` to the last fetched `seq`, and only then drops cancellations that are not for this agent. An agent's own cancellations are never returned. · `lib/c3/sessions.ex:take_notices` · `lib/c3/sessions.ex:cancelled_for?`
**Costs you:** each notice appears once. You cannot list it again later through `/inbox`.

### `last_seen_at` and `last_activity_at` lag by up to the throttle
Both `touch_seen` and `touch_activity` write only when `last_seen_throttle` seconds have passed since the previous write. · `lib/c3/sessions.ex:touch_seen` · `lib/c3/sessions.ex:touch_activity`
**Costs you:** a test or idle check that expects an exact timestamp gets a stale one.

### The JSON never exposes internal ids
Agents appear as `AGn` and threads as `T<number>`. `show` returns `you` as a name, not an agent object. `joins_locked` is a boolean derived from `joins_locked_at`. · `lib/c3_web/controllers/v1/session_json.ex:show` · `lib/c3_web/controllers/v1/session_json.ex:session`

## Known workarounds in the code

- **Session-code collision retry.** `insert_session` rolls back the whole transaction and retries, up to 3 attempts, but only when the changeset errors are exactly `[code: _]`. Postgres aborts a transaction after a constraint error, so retrying inside the same transaction is not possible. · `lib/c3/sessions.ex:insert_session`
- **`Credentials.dummy_verify()` on an unknown code.** It spends the same hashing time as a real secret check, so response timing does not reveal whether a code exists. · `lib/c3/sessions.ex:unknown_code`
- **Conditional `update_all` plus a row-count check.** `maybe_lock_joins` updates only `where is_nil(joins_locked_at)`, and `unlock_joins` only `where not is_nil(...)`. Each emits its event only when the count is `== 1`, so two racing requests produce one event. · `lib/c3/sessions.ex:maybe_lock_joins`
- **`user_agent` truncated to 500 characters** on the agent row only. The failure map passed to `Security.record_failure` gets the raw value. · `lib/c3/sessions.ex:add_agent!`

## Coverage

| Test | Pins |
|---|---|
| `test/c3_web/controllers/v1/session_controller_test.exs` | Credentials returned once; names never reused after a leave; forgiving code format; ban past the tolerance and an alert on every failure; a live token keeps working from a banned IP; a lock after K distinct IPs that lasts until an agent unlocks; joining a closed session gives 410 and no ban; an unknown code bans at the 5th attempt of the day; close is irreversible |
| `test/c3/sessions_test.exs` | Changeset rules (the `AG<number>` name, label format, `left_at` only when inactive, `closed_by` format), uniqueness, `list_agents` in join order |

Gap: these two files contain no test named after `rotate_secret`, `revoke`, `take_notices`, `touch_seen`/`touch_activity`, or the reset of failure counts after a rotation.

## Prior tickets

| Ticket | What it changed | Watch out |
|---|---|---|
| `C3-1` | Sessions, agents, join, lock counting by distinct IP; secret rotation came in a later phase | The original schema design differs from the current migrations. Trust the code. |
| `C3-3` | Bans escalate on repeated failures, and IPv6 bans and lock counts apply to the network, not the single address (`C3.Security.CIDR.subject`) | Ban duration and subject logic live in `C3.Security`, not in this module; see `join-security` |
