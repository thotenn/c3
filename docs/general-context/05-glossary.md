---
doc: general-context/05-glossary
repo: c3
kind: glossary
anchored_to: fa64fbd
generated: 2026-10-02
---
# Glossary — c3 domain words

The words used in c3's sessions, threads, the event feed and join security, mapped to the identifiers that implement them. Mechanisms are explained in the architecture documents and feature indexes linked below. This file only translates between a term and its code name.

## agent (AGn)

One participant in one session. C3 assigns its name as `AG<number>`, numbered per session from `next_agent_number`. The agent that creates the session is `AG1`. An agent row is never deleted on its own: when an agent leaves, its `status` changes and the row stays. Appears in the code as `lib/c3/sessions/agent.ex:C3.Sessions.Agent` (`status`: `:active | :left | :revoked`) · `lib/c3/sessions/session.ex:next_agent_number`. See [`../features/sessions-and-agents/00-INDEX.md`](../features/sessions-and-agents/00-INDEX.md).

**Not to be confused with** label, which is a free name the agent picks for itself. Requests can be addressed to a label, but the label is not the agent's identity.

## alerts_seen_seq

A per-agent cursor into the event log. It marks the point up to which security alerts and `request.cancelled` notices have already been shown to that agent through `/inbox`. `lib/c3/sessions.ex:take_notices` reads every event with `seq > alerts_seen_seq`, then moves the cursor forward. Reading `/inbox` therefore consumes those notices: each one is shown once. Appears in the code as `lib/c3/sessions/agent.ex:alerts_seen_seq` · `lib/c3_web/controllers/v1/inbox_controller.ex:show`.

**Not to be confused with** the watcher's `cursor`, which the client keeps and the server never stores. Polling `/watch` or `/events` does not mark anything as seen.

## answered

A thread status. It means no request in the thread is `open` or `claimed`: all of them are `done` or `cancelled`. It is derived from the requests, not set by any action. Appears in the code as `lib/c3/threads/derivation.ex:derive`.

**Not to be confused with** finished, which is an explicit act of the agent that opened the thread. A new request moves an `answered` thread back to `pending`. A `finished` thread stays finished until it is reopened.

## any

A request target meaning "whoever takes it first". In the watcher (`lib/c3/watch.ex:C3.Watch`) and in the `/inbox` cancellation notices (`lib/c3/sessions.ex:take_notices`), a request to `any` concerns every agent except its author. Appears in the code as `lib/c3/threads/message.ex:to_target` (`:any`) · `lib/c3/threads/targets.ex:resolve` (a `nil` target resolves to `"any"`). See [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md).

## awaiting

The deduplicated list of targets of a thread's `open` requests, in request order. It is computed, not stored. A thread can be `pending` and still have `claimed` requests: those are listed in `processing_by`. Appears in the code as `lib/c3/threads/derivation.ex:derive` · `lib/c3/threads/queries.ex:filter_awaiting` (the `awaiting: me` filter of the thread list).

## ban

An IP-level block, recorded after repeated failed joins. It lasts until the next local midnight (`C3_TZ`) and never applies to an IP in the allowlist. A ban only blocks `create` and `join`: an agent already inside the session keeps working from a banned IP with its token. Appears in the code as `lib/c3/security.ex:ban` · `lib/c3/security/ip_ban.ex` · `lib/c3/security/ban_cache.ex:banned_until`. See [`../features/join-security/00-INDEX.md`](../features/join-security/00-INDEX.md).

**Not to be confused with** joins_locked, which applies to one session for every IP, and stays until someone unlocks it or rotates the secret.

## claim

An agent marks one or more `open` requests as its own (`open → claimed`). It is a conditional `UPDATE … WHERE request_state = 'open'`, so when two agents race for the same request, exactly one wins. A claim goes back to `open` when:
- the agent leaves or is revoked: `lib/c3/threads.ex:release_claims!`
- the agent has not been seen for `claim_ttl`: `lib/c3/threads.ex:expire_claims` emits `request.claim_expired`.

Appears in the code as `lib/c3/threads.ex:claim` · `lib/c3/threads/guards.ex:claimable_request!`.

**Not to be confused with** answering. A claim only reserves the request; a `response` is what resolves it to `done`.

## closing_soon

A warning event, `session.closing_soon`. It is emitted `session_closing_soon` seconds before the session closes, whether the close is coming from idleness or from max TTL. It is emitted again only if activity moved the idle close later in the meantime. Appears in the code as `lib/c3/sessions/lifecycle.ex:warn_closing` · `lib/c3/events/event.ex:session_closing_soon`. See [`../features/session-lifecycle/00-INDEX.md`](../features/session-lifecycle/00-INDEX.md).

## close

Ends the whole session for everyone, and cannot be undone:
- the session's `status` becomes `closed`;
- every active token is revoked;
- every route of the session answers `410` from then on.

`close_reason` is one of `manual`, `idle`, `max_ttl` or `admin`. `closed_by` is the closing agent's name, `"admin"`, or `"system"` when the sweeper closed it. Appears in the code as `lib/c3/sessions.ex:close` · `lib/c3/sessions.ex:close_session!` · `lib/c3/sessions/session.ex:close_reason`.

**Not to be confused with** leave and revoke, which each affect one agent only. Note that a close sets the agents' `status` to `revoked`, so after a close the agent `status` alone does not tell you why an agent was revoked.

## code

The public identifier of a session, in the form `C3-XXXX-XXXX`: 40 random bits in Crockford base32, stored in clear. It appears in URLs (`/sessions/:code/...`). Appears in the code as `lib/c3/credentials.ex:generate_code` · `lib/c3/credentials.ex:normalize_code`.

**Not to be confused with** secret, which is the credential needed to join. Knowing the code alone does not let anyone join.

## cursor

The `seq` of the last event a client has consumed. The client sends it back as `?after=`. `/events` returns it as `last_seq`. `/watch` returns it as a leading `cursor <seq>` line, and moves it past events that do not concern the caller. The watcher script stores it per saved key. Appears in the code as `lib/c3_web/controllers/v1/event_controller.ex:watch` · `plugin/skills/c3/scripts/c3-watch.sh:cursor_of`. See [`../features/event-feed/00-INDEX.md`](../features/event-feed/00-INDEX.md).

## event

One entry in a session's append-only log, for example `thread.opened`, `request.claimed` or `session.closed`. The full list of types is `lib/c3/events/event.ex:@types`. Events are written in the same transaction as the change they record. Appears in the code as `lib/c3/events/event.ex:C3.Events.Event` · `lib/c3/events.ex:append!`. Fan-out is explained in [`../architecture/04-processes-and-background-work.md`](../architecture/04-processes-and-background-work.md).

## events feed vs /watch vs /inbox

Three ways to read what happened. None of them counts as session activity, with one exception noted below.

| Endpoint | Returns | State it changes |
|---|---|---|
| `GET /sessions/:code/events` (and `/events/stream`, SSE) | Every event, as JSON | None |
| `GET /sessions/:code/watch` | Only the events that concern the caller, one line each, `text/plain` | None |
| `GET /inbox` | Open and claimed requests, plus cancellation and security notices not yet seen | Moves `alerts_seen_seq` forward |

- `/watch` decides relevance in `lib/c3/watch.ex:line`, so the shell watcher never has to parse JSON. It holds the request until something relevant arrives.
- The events feed and `/heartbeat` are routed with `activity: false` (`lib/c3_web/plugs/agent_auth.ex:C3Web.Plugs.AgentAuth`). `/inbox` is not, so reading it does count as activity on the session.

## finished

A thread status, set explicitly by the agent that opened the thread. Only that agent can undo it, by reopening the thread. The finish fails while requests are still pending, unless forced: forcing cancels them. It takes precedence over every other rule in `lib/c3/threads/derivation.ex:derive`. Appears in the code as `lib/c3/threads/thread.ex:finished_at`.

**Not to be confused with** answered (see that entry).

## joins_locked

A per-session lock that refuses every join, from any IP. It is set when wrong secrets for that session come from too many distinct IPs, and emits `session.joins_locked`. A join attempt while locked is recorded as `:joins_locked` but never leads to a ban. The lock is lifted by an unlock or by rotating the secret. Appears in the code as `lib/c3/sessions/session.ex:joins_locked_at` · `lib/c3/sessions.ex:join_session` · `lib/c3/security/join_failure.ex` (reason `:joins_locked`). See [`../features/join-security/00-INDEX.md`](../features/join-security/00-INDEX.md).

## label

An optional free name an agent gives itself. It must match `^[a-z0-9][a-z0-9-]{0,39}$`. Requests can be addressed to `label:<x>`. Appears in the code as `lib/c3/sessions/agent.ex:@label_format` · `lib/c3/threads/message.ex:to_label`.

**Not to be confused with** the session's own `label` (`lib/c3/sessions/session.ex:label`), which is only a display name for the session.

## last_seen_at vs last_activity_at

Two timestamps that look alike and do different jobs:

| Field | Belongs to | Purpose | Updated by |
|---|---|---|---|
| `last_seen_at` | Agent | Presence: keeps the agent's claims from expiring (`claim_ttl`) | Every authenticated request, including the event feed and `/heartbeat` |
| `last_activity_at` | Session | Keeps the session open: pushes back the idle close (`session_idle_ttl`) | Authenticated requests except the event feed and `/heartbeat` |

- Code: `lib/c3/sessions.ex:touch_seen` updates `last_seen_at`; `lib/c3/sessions.ex:touch_activity` updates `last_activity_at`.
- Both writes are throttled by `last_seen_throttle`, so the stored value can be up to 60 seconds behind.
- The asymmetry is deliberate: a forgotten watcher keeps its agent "present" but does not keep the session alive. See [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md).

## leave vs revoke vs close

| Action | Who does it | Agent ends as | Claims | Event |
|---|---|---|---|---|
| leave | The agent itself | `left` | Back to `open` | `agent.left` |
| revoke | The admin | `revoked` | Back to `open` | `agent.revoked` (`by: "admin"`) |
| close | Any agent, the admin, or the sweeper | Every active agent ends `revoked` | Not released one by one | `session.closed` |

Code: `lib/c3/sessions.ex:leave` · `lib/c3/sessions.ex:revoke` · `lib/c3/sessions.ex:close_session!`.

## message (Tn.m)

An entry in a thread, referenced as `T<thread>.<number>`. Its `kind` is `request`, `response`, `note` or `system`. The body is append-only: only the `request_*`, `claimed_*` and `resolved_at` columns change after creation. Appears in the code as `lib/c3/threads/message.ex:C3.Threads.Message` · `lib/c3/threads/refs.ex:message_ref`.

## note

A message that neither asks for anything nor resolves anything. It has no `request_state` and no effect on the thread's status. Appears in the code as `lib/c3/threads/message.ex:kind` (`:note`).

## purge

Permanent deletion of a closed session and everything in it, including its attachment files. It runs automatically after `retention_days`, or immediately at the admin's request. It refuses an open session (`:not_closed`). Appears in the code as `lib/c3/sessions/lifecycle.ex:purge` · `lib/c3/sessions/lifecycle.ex:purge_session`.

**Not to be confused with** `lib/c3/security.ex:purge_history`, which removes only security history (join failures and ended bans) older than 30 days, and `lib/c3/idempotency.ex:purge`, which removes old idempotency keys.

## request

A message that asks one target for something: an agent, a label, or `any`. Addressing several targets creates one request per target. A request carries its own state, described under request_state. Appears in the code as `lib/c3/threads/message.ex:kind` (`:request`) · `lib/c3/threads/targets.ex:resolve`.

**Not to be confused with** an HTTP request, and not with a message in general: only messages of kind `request` have a state.

## request_state vs thread status

Two separate state machines:

- **request_state** belongs to each request: `open → claimed → done`, or `cancelled`. It is stored in `lib/c3/threads/message.ex:request_state`.
- **Thread status** is `pending`, `processing`, `answered` or `finished`. It is a cached value derived from the thread's request states by `lib/c3/threads/derivation.ex:derive`, and only `C3.Threads` writes it, in the same transaction that changed the requests (`lib/c3/threads/thread.ex:C3.Threads.Thread`).

Derivation order:
1. `finished`, if the thread was finished and not reopened;
2. otherwise `pending`, if any request is `open`;
3. otherwise `processing`, if any request is `claimed`;
4. otherwise `answered`.

Never write a thread's `status` directly.

## response

A message that resolves requests (`→ done`). It names them through `reply_to`, or resolves the requests in the thread that its author holds. It wakes the requests' authors with an `answer` line (`resolved_for`). Appears in the code as `lib/c3/threads/message.ex:kind` (`:response`) · `lib/c3/watch.ex:line`.

## secret

The numeric security number needed to join a session. It is shown once, at creation or rotation, and stored as an Argon2id hash: a slow hash because the secret has low entropy. Wrong secrets lead to bans and to joins_locked. Appears in the code as `lib/c3/credentials.ex:generate_secret` · `lib/c3/sessions/session.ex:secret_hash`.

## seq

The position of an event in its session's log. It increases without gaps within one session and is allocated from `event_seq`. It is the unit of every cursor. Appears in the code as `lib/c3/events/event.ex:seq` · `lib/c3/sessions/session.ex:event_seq`.

## session

One coordination space, identified by its code and joined with its secret. Its `status` is `open` or `closed`, and `closed` is terminal. It closes when an agent or the admin closes it, after inactivity (`last_activity_at`), or at `expires_at` (max TTL). Appears in the code as `lib/c3/sessions/session.ex:C3.Sessions.Session`. See [`../features/session-lifecycle/00-INDEX.md`](../features/session-lifecycle/00-INDEX.md).

## system

1. A message `kind` that has no author agent: `lib/c3/threads/message.ex:kind` (`:system`) allows `author_agent_id` to be empty only for this kind.
2. The `closed_by` value written when the sweeper closes a session: `lib/c3/sessions.ex:close_session!`.

## thread (Tn)

A conversation inside a session, referenced as `T<number>`, with a title, an opener (`opened_by_agent`) and a derived `status`. Appears in the code as `lib/c3/threads/thread.ex:C3.Threads.Thread` · `lib/c3/threads/refs.ex:thread_ref`. See [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md).

## token

An agent's bearer credential: 256 random bits, returned once, at create or join. Only its SHA-256 is stored, so a request can look up its agent by `token_hash`. A token stops working on leave, revoke or close. A token revoked by a close gets `410`, not `401`. Appears in the code as `lib/c3/credentials.ex:generate_token` · `lib/c3/credentials.ex:hash_token` · `lib/c3_web/plugs/agent_auth.ex:C3Web.Plugs.AgentAuth`. See [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md).

## watch / watcher

The Claude Code plugin's shell script. It long-polls `/watch` and exits on the first line that concerns its agent, which wakes that agent. Each line has the form `<kind> <seq> <facts…>`, where `kind` is one of `request`, `answer`, `cancelled`, `claim_expired`, `joined`, `security`, `closing_soon` or `stop`. Nothing an agent did itself ever wakes it. Appears in the code as `plugin/skills/c3/scripts/c3-watch.sh` · `lib/c3/watch.ex:C3.Watch`. See [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md).
