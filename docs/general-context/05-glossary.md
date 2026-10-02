---
doc: general-context/05-glossary
repo: c3
kind: glossary
anchored_to: e99b2ae
generated: 2026-10-02
---
# Glossary — c3 domain words

These are the words of the c3 coordination model: sessions, agents, threads, requests, the event log and join security. This repo has no shared glossary, so every term is defined here.

## Agent (AGn)

A participant in a session, usually one Claude Code instance. Each agent gets a number, a name `AG<n>` and its own token. The agent that creates the session is `AG1`. In the code: `lib/c3/sessions/agent.ex:C3.Sessions.Agent`. Its `status` is `:active`, `:left` or `:revoked`. See [`../features/sessions-and-agents/00-INDEX.md`](../features/sessions-and-agents/00-INDEX.md).

**Not to be confused with** the admin. The admin is a human in the admin UI and has no `AGn`. When the admin acts, `closed_by` is recorded as `"admin"` (`lib/c3/sessions.ex:close_session!`).

## alerts_seen_seq

A per-agent cursor in the event log. It makes `/inbox` show each security alert and each relevant `request.cancelled` only once. `lib/c3/sessions.ex:take_notices` reads the events with `seq > alerts_seen_seq` and then moves the cursor forward. Field: `lib/c3/sessions/agent.ex:alerts_seen_seq`.

**Not to be confused with** the watcher's `cursor`. The watcher's cursor lives on the client and is sent back as `after`. `alerts_seen_seq` is stored on the server, and reading `/inbox` moves it forward. Reading `/inbox` therefore uses up those notices.

## any

A request target that means "whoever takes it". Code: `lib/c3/threads/targets.ex:resolve`, which maps a `nil` target to `"any"`, and `to_target: :any` in `lib/c3/threads/message.ex:C3.Threads.Message`. A request to `any` never reaches its own author, neither in the watcher (`lib/c3/watch.ex:C3.Watch`) nor in cancellation notices (`lib/c3/sessions.ex:take_notices`).

## Awaiting

The derived list of targets that still have an `open` request in a thread. Computed in `lib/c3/threads/derivation.ex:derive`. Used as a list filter in `lib/c3/threads/queries.ex:filter_awaiting`. A thread can be awaiting someone and also have claimed requests in progress, which are listed in `processing_by`.

**Not to be confused with** the inbox. `awaiting` belongs to a thread. The inbox belongs to one agent and also includes the requests that agent has claimed.

## Ban

A block on an IP for `create` and `join` only, which lasts until `banned_until`. In the code: `lib/c3/security/ip_ban.ex:C3.Security.IpBan`, with `reason` set to `:invalid_secret`, `:unknown_code` or `:admin`. The table is the source of truth, and active bans are copied into ETS by `lib/c3/security/ban_cache.ex`. A live token keeps working from a banned IP (`lib/c3_web/plugs/agent_auth.ex:C3Web.Plugs.AgentAuth`). See [`../features/join-security/00-INDEX.md`](../features/join-security/00-INDEX.md).

**Not to be confused with** `joins_locked`. A ban applies to one IP across all sessions. A join lock applies to one session for every IP.

## Claim

An agent takes an open request so that nobody else takes it: `request_state` goes from `:open` to `:claimed`. Done by `lib/c3/threads.ex:claim` and checked by `lib/c3/threads/guards.ex:claimable_request!`. A claim goes back to `open` in three cases:
- the agent leaves or is revoked (`lib/c3/threads.ex:release_claims!`);
- the agent has not been seen for `claim_ttl` (`lib/c3/threads.ex:expire_claims`, which emits `request.claim_expired`).

## closing_soon

A warning event, `session.closing_soon`. It is emitted `session_closing_soon` seconds before an idle close or a max-TTL close, by `lib/c3/sessions/lifecycle.ex:warn_closing`. The watcher prints it as a line of kind `closing_soon`. See [`../features/session-lifecycle/00-INDEX.md`](../features/session-lifecycle/00-INDEX.md).

## Code (session code)

The public identifier of a session, in the form `C3-XXXX-XXXX` (40 random bits, Crockford base32). It is stored in clear. In the code: `lib/c3/credentials.ex:generate_code` and `lib/c3/credentials.ex:normalize_code`.

**Not to be confused with** the secret. The code is shared openly. The secret is what proves the right to join.

## Cursor

The last event `seq` a client has consumed. The client sends it back as `after` on its next call. `/watch` returns `cursor <n>` as its first line, and that cursor also skips past events that were not relevant to the agent (`lib/c3_web/controllers/v1/event_controller.ex:watch`). The SSE stream uses `Last-Event-ID` instead (`lib/c3_web/controllers/v1/event_controller.ex:stream`).

## Event / seq

One entry of a session's append-only log. Its types are listed in `lib/c3/events/event.ex:C3.Events.Event`. `seq` grows by one per session with no gaps, and is assigned by `lib/c3/events.ex:append!`. See [`../features/event-feed/00-INDEX.md`](../features/event-feed/00-INDEX.md).

**Not to be confused with** a message. Messages are the content of a thread. Events are the notifications about what happened, including messages being posted.

## Events feed vs /watch vs /inbox

These are three ways to read what happened, and each returns something different:
- `GET /sessions/:code/events` (`lib/c3_web/controllers/v1/event_controller.ex:index`) returns raw JSON events after a cursor, for any agent in the session. It can long-poll.
- `GET /sessions/:code/watch` (`lib/c3_web/controllers/v1/event_controller.ex:watch`) returns plain-text lines that concern only the calling agent, built by `lib/c3/watch.ex:line`. It is meant for the curl-only watcher script `plugin/skills/c3/scripts/c3-watch.sh`.
- `GET /inbox` (`lib/c3_web/controllers/v1/inbox_controller.ex`) returns the current work state: open requests addressed to the agent and the requests it has claimed (`lib/c3/threads/queries.ex:inbox`). It also returns the once-only notices described under `alerts_seen_seq`.

The feed and `/heartbeat` are mounted with `activity: false`. They count as presence, not as session activity. See [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md).

## Inbox

What one agent has to act on. See *Events feed vs /watch vs /inbox*.

## joins_locked

A session state in which new joins are refused for everyone. It is set in `joins_locked_at` (`lib/c3/sessions/session.ex:C3.Sessions.Session`) after repeated wrong secrets from several IPs, and emits `session.joins_locked`. A join attempt in this state is recorded as `:joins_locked` but never banned (`lib/c3/sessions.ex:join_session`). It is cleared by `lib/c3/sessions.ex:unlock_joins` or by `lib/c3/sessions.ex:rotate_secret`. Agents that are already in the session keep working.

## Label

An optional free tag on an agent. A request addressed to `label:<x>` reaches every agent with that label. In the code: `lib/c3/threads/targets.ex:C3.Threads.Targets` (`to_target: :label` with `to_label`) and `lib/c3/threads/queries.ex:addressed_to`. A session also has its own optional `label`, which is unrelated to agent labels.

## last_seen_at vs last_activity_at

These two timestamps look alike but control different timeouts:
- `last_seen_at` (`lib/c3/sessions/agent.ex:last_seen_at`) is agent presence. Any authenticated call updates it through `lib/c3/sessions.ex:touch_seen`. It decides whether that agent's claims expire.
- `last_activity_at` (`lib/c3/sessions/session.ex:last_activity_at`) belongs to the session and postpones the idle close. It is updated through `lib/c3/sessions.ex:touch_activity`, but not by the event feed, `/watch` or `/heartbeat` (`lib/c3_web/plugs/agent_auth.ex:C3Web.Plugs.AgentAuth`).

The trap: a running watcher keeps the agent's claims alive, but it does not keep the session open. Both writes are throttled by `:last_seen_throttle` (`lib/c3/config.ex:last_seen_throttle`).

## Leave vs revoke vs close

These are three different ways to end participation:
- **Leave** is the agent's own action (`lib/c3/sessions.ex:leave`). Its status becomes `:left`, its claims are released and `agent.left` is emitted. Calls with its token then get `401`.
- **Revoke** is the admin's action (`lib/c3/sessions.ex:revoke`). It has the same effect, but the status becomes `:revoked` and the event is `agent.revoked` with `by: "admin"`.
- **Close** ends the whole session (`lib/c3/sessions.ex:close` → `lib/c3/sessions.ex:close_session!`). Every token is revoked and every route of the session returns `410`. `close_reason` is `:manual`, `:idle`, `:max_ttl` or `:admin`.

## Message (Tn.m)

One append-only entry in a thread, addressed as `T<thread>.<n>` (`lib/c3/threads/refs.ex:message_ref`). Its `kind` is `:request`, `:response`, `:note` or `:system` (`lib/c3/threads/message.ex:C3.Threads.Message`).

**Not to be confused with** a request. A request is one kind of message, and only requests have `to_target` and `request_state`.

## Note

A message that asks for nothing and resolves nothing (`kind: :note`).

## Purge

The deletion of a closed session and everything in it, run once `retention_days` has passed (`lib/c3/sessions/lifecycle.ex:purge`) or on demand by the admin (`lib/c3/sessions/lifecycle.ex:purge_session`). An open session cannot be purged (`:not_closed`). Files are deleted after their rows.

**Not to be confused with** close, which keeps all the data. Also not with `lib/c3/security.ex:purge_history` and `lib/c3/idempotency.ex:purge`, which prune other tables.

## Request

A message that asks a target for something, with its own `request_state`: `:open`, `:claimed`, `:done` or `:cancelled` (`lib/c3/threads/message.ex:request_state`). A thread opened with several targets creates one request per recipient. Cancelling is done by `lib/c3/threads.ex:cancel`. See [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md).

## Response

A message that resolves a request, moving it to `:done`. A response wakes the request's author with a watcher line of kind `answer` (`lib/c3/watch.ex:C3.Watch`).

## Secret (security number)

The numeric secret needed to join a session (`lib/c3/credentials.ex:generate_secret`). It is stored as an Argon2id hash, because a short number needs a slow hash. It is shown only once, at creation, and can be replaced with `lib/c3/sessions.ex:rotate_secret`. Wrong secrets lead to bans.

## Session

The shared space for one task, identified by its code. Its `status` is `:open` or `:closed` (`lib/c3/sessions/session.ex:C3.Sessions.Session`).

**Not to be confused with** the admin's browser login session (`lib/c3_web/controllers/admin_session_controller.ex`), or with a Claude Code session.

## system

Two meanings:
- a message with `kind: :system`, which has no author (`lib/c3/threads/message.ex:C3.Threads.Message`);
- the `closed_by` value `"system"` when the sweeper closes a session (`lib/c3/sessions.ex:close_session!`).

## Thread (Tn)

A conversation opened by one agent with a first request, addressed as `T<n>` (`lib/c3/threads/refs.ex:thread_ref`). Its `status` is derived from its requests (`lib/c3/threads/derivation.ex:derive`):
- `finished` if its opener finished it;
- `pending` if any request is `open`;
- `processing` if any request is `claimed`;
- `answered` otherwise.

Only the opener can finish a thread (`lib/c3/threads.ex:finish`) or reopen it (`lib/c3/threads.ex:reopen`).

**Not to be confused with** `request_state`. Thread status describes the whole thread, while `request_state` describes one message. In particular, **answered ≠ finished**: `answered` only means no request is pending, and the thread stays open until its opener finishes it.

## Token

An agent's bearer credential: 256 random bits, stored as a SHA-256 hash (`lib/c3/credentials.ex:generate_token`, `lib/c3/credentials.ex:hash_token`). It is returned once, on create or join. See [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md).

## Watch / watcher

The background shell script `plugin/skills/c3/scripts/c3-watch.sh`, which long-polls `/watch` and wakes the agent with one line per relevant event. The server decides what counts as relevant (`lib/c3/watch.ex:C3.Watch`). An agent's own actions never wake it.
