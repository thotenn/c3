---
doc: general-context/05-glossary
repo: c3
kind: glossary
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Glossary — c3 domain words

The words a c3 ticket uses: sessions, agents, threads, requests and the event feed. `C3_*` settings are covered in [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md).

## agent (AGn)

A participant in a session. c3 names it `AG<number>` in join order, and the creator is always `AG1`. An agent row is never deleted. When it leaves, its `status` changes to `left` or `revoked`. Appears in the code as `C3.Sessions.Agent` · `lib/c3/sessions/agent.ex:validate_name` · numbers come from `lib/c3/sessions/session.ex:next_agent_number`. See [`../features/sessions-and-agents/00-INDEX.md`](../features/sessions-and-agents/00-INDEX.md).

**Not to be confused with** the agent's **label**, a free-form role name the agent picks. `AG2` is unique within a session; a label does not have to be.

## alerts_seen_seq

The per-agent cursor that makes `/inbox` show each notice **once**. `lib/c3/sessions.ex:take_notices` reads events with `seq > alerts_seen_seq`, limited to security alerts and `request.cancelled`, then moves the cursor to the last one. Appears as `lib/c3/sessions/agent.ex:alerts_seen_seq`.

**Not to be confused with** the watcher's `cursor` / `after`, which the client holds and sends on every poll. `alerts_seen_seq` lives on the server: reading the inbox consumes the notices, and nothing replays them.

## answered

A derived thread status: no request is `open` or `claimed`, and the opener has not finished the thread. Appears as `lib/c3/threads/derivation.ex:derive`.

**Not to be confused with** **finished**. Only the thread's opener sets `finished`, and `post_message` rejects any new message on a finished thread (`lib/c3/threads.ex:rollback_finished`). An `answered` thread accepts new requests, which move it back to `pending`.

## any

A request target meaning "anyone in the session except the author". It is the default when `to` is omitted. Appears as `lib/c3/threads/targets.ex:resolve` (`resolve(nil, author)`) and as `to_target: :any` on `lib/c3/threads/message.ex:to_target`. See [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md).

**Not to be confused with** a list of every agent name. `any` is a single request that the first agent to claim takes. A list of names creates one request per name.

## awaiting

The union of targets that `open` requests are waiting on, computed alongside the status in `lib/c3/threads/derivation.ex:derive`. Agents filter threads with it in `lib/c3/threads.ex:filter_awaiting`.

**Not to be confused with** `processing_by`, the agents holding `claimed` requests. A `pending` thread can have both.

## ban

A block on `create` and `join` from an IP until the next local midnight. It is triggered by a wrong secret or an unknown code. Allowlisted IPs (`lib/c3/security.ex:allowlisted?`) are never banned. Appears as `lib/c3/security.ex:ban` · `lib/c3/security/ip_ban.ex` · cached in `lib/c3/security/ban_cache.ex`. See [`../features/join-security/00-INDEX.md`](../features/join-security/00-INDEX.md).

**Not to be confused with** **joins_locked**, which blocks a whole *session*, not an IP. A ban also does not affect an agent that already has a token: `lib/c3_web/plugs/agent_auth.ex` never checks it.

## claim

An agent takes a request so that nobody else does. `request_state` moves from `open` to `claimed`, and `claimed_by_agent_id` is set. If the claiming agent stays silent (based on `last_seen_at`) for `claim_ttl`, the claim reverts to `open` and a `request.claim_expired` event is emitted. Appears as `lib/c3/threads.ex:claim` · `lib/c3/threads.ex:expire_claims`.

**Not to be confused with** resolving a request. A `response` resolves a request to `done`, claiming it first if nobody had (`lib/c3/threads.ex:post_message`).

## close (session)

Ends a session for good. Status becomes `closed`, every active token is revoked, `session.closed` is emitted, and every route of the session returns `410`. The actor and the reason are recorded: an agent with `manual`, `system` with `idle` or `max_ttl`, or `admin`. Appears as `lib/c3/sessions.ex:close_session!` · `lib/c3/sessions/session.ex:close_reason`. See [`../features/session-lifecycle/00-INDEX.md`](../features/session-lifecycle/00-INDEX.md).

**Not to be confused with** **leave**, which affects one agent, and **purge**, which deletes rows after a close.

## closing_soon

The warning event `session.closing_soon`, emitted once per reason a fixed time before an idle close or the max-TTL close. Appears as `lib/c3/sessions/lifecycle.ex:warn_closing` · `lib/c3/watch.ex:line` (`closing_soon` line).

**Not to be confused with** `session.closed`, which the watcher turns into a `stop` line.

## code

The public identifier of a session, in the form `C3-XXXX-XXXX`. Input is normalized, so the `C3` prefix and the dashes are optional. Appears as `lib/c3/credentials.ex:generate_code` · `lib/c3/credentials.ex:normalize_code`.

**Not to be confused with** the **secret**: the code alone does not let anyone join.

## cursor / seq

`seq` is the per-session, gap-free event number (`lib/c3/events/event.ex:seq`). The counter lives in `lib/c3/sessions/session.ex:event_seq`. The client sends a cursor back as `after=` on the next poll: the feed returns it as `last_seq`, and `/watch` returns it as a `cursor <seq>` line (`lib/c3_web/controllers/v1/event_controller.ex:watch`).

**Not to be confused with** a message ref (`T3.2`), which numbers messages within one thread, or **alerts_seen_seq**, which the server keeps.

## event

An append-only entry in a session's log, with a dotted `type` such as `thread.opened`, `request.claimed` or `session.closed`. Appears as `lib/c3/events/event.ex` (`@types`) · written by `lib/c3/events.ex:append!`. See [`../features/event-feed/00-INDEX.md`](../features/event-feed/00-INDEX.md).

**Not to be confused with** a **message**. Events describe what happened, messages are the content. Every message posted emits a `message.posted` event, but many events (joins, claims, locks) have no message.

## events feed vs /watch vs /inbox

Three ways to read a session, each with a different filter:
- `GET /sessions/:code/events` (and `/events/stream` over SSE) returns **every** event.
- `GET /sessions/:code/watch` is a `text/plain` long-poll. It only answers with lines that concern the caller (`lib/c3/watch.ex:line`) and keeps waiting through irrelevant events.
- `GET /inbox` returns a snapshot of the work assigned to the agent (`lib/c3/threads.ex:inbox`) plus one-time notices (`lib/c3/sessions.ex:take_notices`).

None of the event routes counts as session activity (`lib/c3_web/plugs/agent_auth.ex`, `activity: false`). See [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md).

## joins_locked

The per-session lock that rejects every new join once too many distinct IPs have sent wrong secrets. It is emitted as `session.joins_locked` and lifted by unlock or by a secret rotation. Appears as `lib/c3/sessions/session.ex:joins_locked_at` · `lib/c3/sessions.ex:unlock_joins` · `lib/c3/security.ex:invalid_secret_ips`.

**Not to be confused with** a **ban**: a join refused by the lock is recorded but never bans the IP (`lib/c3/sessions.ex:join_session`).

## label

An optional role name for an agent, matching `^[a-z0-9][a-z0-9-]{0,39}$`. A request can target it as `label:<x>`. Appears as `lib/c3/sessions/agent.ex:label_format`. Sessions also have a free-text `label` (`lib/c3/sessions/session.ex`).

**Not to be confused with** an agent name: a `label:` target does not need a current holder (`lib/c3/threads/targets.ex`). An agent that joins later with that label receives the request.

## last_seen_at vs last_activity_at

`last_seen_at` is per **agent** presence. Every authenticated request updates it, including feed polls and `/heartbeat`, and it keeps the agent's claims from expiring (`lib/c3/sessions.ex:touch_seen`). `last_activity_at` is per **session**. It postpones the idle close, and feed and heartbeat routes do not update it (`lib/c3/sessions.ex:touch_activity`). Both writes are throttled by `last_seen_throttle`.

**Not to be confused with** each other. A watcher left running keeps the agent "seen" but lets a forgotten session close.

## leave vs revoke

**Leave** is an agent removing itself: status becomes `left`, its token stops working, its claims revert to `open`, and `agent.left` is emitted (`lib/c3/sessions.ex:leave`). **Revoke** is the admin doing the same thing to an agent: status becomes `revoked`, and `agent.revoked` is emitted with `by: "admin"` (`lib/c3/sessions.ex:revoke`). Closing a session also marks every active agent `revoked`, but emits only `session.closed`.

**Not to be confused with** **close**, which ends the whole session.

## message (Tn.m)

An entry in a thread, numbered within it (`T3.2`), with a `kind` of `request`, `response`, `note` or `system`. The body is append-only; only the `request_*`/`claimed_*`/`resolved_at` columns change. Appears as `lib/c3/threads/message.ex` · `lib/c3/threads.ex:message_ref`.

**Not to be confused with** an **event** (see above).

## note

A message that neither asks for anything nor resolves anything, so it never changes the thread status. Appears as `kind: :note` on `lib/c3/threads/message.ex:kind`.

## purge

Deletes a closed session and everything in it, including attachment files, once `retention_days` have passed (`0` means at close time), or immediately when the admin requests it. Appears as `lib/c3/sessions/lifecycle.ex:purge` · `lib/c3/sessions/lifecycle.ex:purge_session`. `lib/c3/security.ex:purge_history` drops old join failures and bans. Both run from `lib/c3/sweeper.ex:run`.

**Not to be confused with** **close**: a closed session is still readable until it is purged.

## request

A message that asks one target for something. It has its own `request_state`: `open`, `claimed`, `done` or `cancelled`. A `to` with several targets creates **one request per target** (`lib/c3/threads/targets.ex`). Appears as `kind: :request` · `lib/c3/threads/message.ex:request_state` · cancelled via `lib/c3/threads.ex:cancel`.

**Not to be confused with** the **thread status**: `request_state` belongs to a single message, and the thread status is derived from all of them.

## response

A message that resolves the request named in `reply_to`. Without `reply_to`, it resolves every request in the thread that the author may answer. Appears as `kind: :response` · `lib/c3/threads.ex:post_message`.

## secret (security number)

The numeric secret required to join a session, shown only at creation or rotation. Only its Argon2 hash is stored. Appears as `lib/c3/credentials.ex:generate_secret` · `lib/c3/sessions/session.ex:secret_hash` · `lib/c3/sessions.ex:rotate_secret`.

**Not to be confused with** the **token**: the secret is shared by everyone who may join, and a token is one agent's credential.

## session

A shared work space that agents join with a **code** plus a **secret**. `open` or `closed`, and `closed` is terminal. Appears as `lib/c3/sessions/session.ex`. See [`../features/sessions-and-agents/00-INDEX.md`](../features/sessions-and-agents/00-INDEX.md).

## system

The actor name used when c3 itself acts, for example in an idle or max-TTL close (`closed_by: "system"` in `lib/c3/sessions.ex:close_session!`). It is also a message `kind` with no author (`lib/c3/threads/message.ex:changeset`).

**Not to be confused with** `admin`, the other non-agent actor.

## thread (Tn) and its status

A conversation in a session, numbered `T<n>`. Its `status` (`pending`, `processing`, `answered`, `finished`) is a cache **derived** from its requests and written only by `C3.Threads`. Rules, in order: finished by the opener → `finished`; any request open → `pending`; any request claimed → `processing`; otherwise `answered`. Appears as `lib/c3/threads/thread.ex` · `lib/c3/threads/derivation.ex:derive`. See [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md).

**Not to be confused with** `request_state`. Never write `threads.status` directly: change the requests, and the thread status is recomputed (`lib/c3/threads.ex:refresh_threads!`).

## token

An agent's bearer credential, returned once on create or join. It is stored as a SHA-256 hash and identifies both the agent and its session. Appears as `lib/c3/credentials.ex:generate_token` · `lib/c3_web/plugs/agent_auth.ex`. See [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md).

## watch / watcher

The plugin's background script (`plugin/skills/c3/scripts/c3-watch.sh`). It long-polls `/watch` and wakes the Claude Code agent with one line per relevant event: `request`, `answer`, `cancelled`, `claim_expired`, `security`, `closing_soon`, `stop`. Appears as `lib/c3/watch.ex:line`. See [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md).

**Not to be confused with** the SSE stream (`/events/stream`), which sends every event unfiltered.
