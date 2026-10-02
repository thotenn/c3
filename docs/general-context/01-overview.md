---
doc: general-context/01-overview
repo: c3
kind: general
anchored_to: fa64fbd
generated: 2026-10-02
---
# What c3 is

c3 (Central Context Coordinator) is a message bus with state for AI agents, mostly Claude Code instances, that run on different machines and have to work on the same task. Without it, a human copies text from one agent's terminal into another's. With c3, an agent opens or joins a **session**, writes **requests** to other agents inside **threads**, and reads an **inbox** of what is addressed to it. Agents reach the server through REST (`/v1`) or MCP (`/mcp`). Both paths run through the same Phoenix router, so they can't behave differently. A few decisions shape the rest of the code: a thread's status is derived from its requests, one request has exactly one recipient, the session secret is only used to join, and an IP ban never cuts off a token that is already authenticated.

## Who calls it

| Caller | Door | Where |
|---|---|---|
| An agent with an HTTP client | REST under `/v1` | `lib/c3_web/router.ex` (`scope "/v1"`), controllers in `lib/c3_web/controllers/v1/` |
| A Claude Code agent with the plugin | MCP over Streamable HTTP, `POST /mcp` | `plugin/.mcp.json` (`${user_config.server_url}/mcp`), `lib/c3_web/mcp/server.ex:C3Web.MCP.Server` |
| The plugin's background watcher | the event feed (SSE / long poll) | `plugin/skills/c3/scripts/c3-watch.sh`, `lib/c3_web/controllers/v1/event_controller.ex` |
| A human operator | the admin UI under `/admin` | `lib/c3_web/live/admin/sessions_live.ex`, `lib/c3_web/live/admin/session_live.ex` |
| A metrics scraper | `/metrics` | `lib/c3_web/controllers/metrics_controller.ex` |

The skill the agent follows (create, join, open a thread, claim, answer, keep the watcher running) is in `plugin/skills/c3/SKILL.md`.

## The ideas that decide how the code reads

### Thread state is derived, and the `status` column is a cache

A thread's state is computed by a pure function of its requests, `lib/c3/threads/derivation.ex:derive`. The rules apply in this order:

1. `finished` if its opener finished it.
2. `pending` if any request is `open`.
3. `processing` if any request is `claimed`.
4. `answered` otherwise.

`awaiting` and `processing_by` are always computed as well, so a `pending` thread can also show who is working on it. The `threads.status` column (`lib/c3/threads/thread.ex:C3.Threads.Thread`) is a cache of that result. Only `C3.Threads` writes it, inside the same transaction that changed the requests. Recomputation goes through `lib/c3/threads.ex:refresh_threads!`.

**Touch this when** you add a request state or a way to change one. Change the derivation and call the refresh. Never set `status` directly.

### One request = one recipient

A request's `to` field can be an agent name, a list of names, `label:<x>`, or `any`. If `to` is omitted, it means `any`. `lib/c3/threads/targets.ex:resolve` turns that into a list of targets, and **each target becomes its own request**. A list in `to` therefore creates several requests, and each one is claimed, answered, cancelled and expired on its own. Repeated targets are dropped. Nobody can address themselves, and `any` already excludes the author. A label needs no current holder, so an agent with that label can join later. A named agent must be in the session and active.

### `any` and `label:` are resolved by the first answer

A request to `any` or `label:<x>` is stored with that target type (`to_target: :any` / `:label`, see `lib/c3/threads.ex`), not with an agent. The first eligible agent to claim or answer it becomes its owner. `lib/c3/threads.ex:resolve!` sets `claimed_by_agent_id` to that agent on an `open` request, but only closes a `claimed` request if the same agent claimed it. How the inbox decides who is eligible is in the threads feature.

### The secret only serves the join; everything else uses per-agent tokens

A session has a numeric security number. It is stored as an Argon2id hash (`lib/c3/credentials.ex:hash_secret`, `lib/c3/credentials.ex:verify_secret`) and checked only by `lib/c3/sessions.ex:join_session`. Creating or joining a session returns an agent token: 256 random bits, stored as its SHA-256 so that a request can find its agent by `token_hash` (`lib/c3/credentials.ex`, `lib/c3/sessions.ex:get_agent_by_token`). Every later call authenticates with that token through `lib/c3_web/plugs/agent_auth.ex:C3Web.Plugs.AgentAuth`. Rotating the secret (`lib/c3/sessions.ex:rotate_secret`) blocks new joins and leaves existing agents untouched.

### An IP ban never cuts off an authenticated token

A wrong secret or an unknown session code gets the IP banned (`lib/c3/security.ex:ban`, cached in `lib/c3/security/ban_cache.ex`). The ban is checked only on create and join, by `check_ban` in `lib/c3/sessions.ex:create_session` / `lib/c3/sessions.ex:join_session`. `AgentAuth` deliberately does not check it: "a live token works from a banned IP". This matters because agents behind the same NAT, or a typo on another machine, must not knock out a working agent.

### Two doors, one router

`/mcp` doesn't have its own business logic. `lib/c3_web/mcp/tools.ex` maps each tool call to a REST request. `lib/c3_web/mcp/dispatch.ex:run` builds a `Plug.Conn` with an in-memory adapter (`C3Web.MCP.Dispatch.Adapter`) and calls `C3Web.Router` in-process. The call then passes through `AgentAuth`, the per-token rate limit, idempotency, the controllers, `FallbackController` and the JSON views, the same as a REST client. A c3 error comes back as an MCP tool error (`isError: true` inside a `200`), not as an HTTP error. An HTTP `401` would push the MCP client into an OAuth flow (`lib/c3_web/mcp/server.ex`).

**Touch this when** you add an endpoint. Add the REST route first. The MCP tool is a thin mapping onto it, and it cannot drift from REST.

### No process per session

MCP is stateless: the agent is the `token` argument of each tool, and `initialize` for older protocol versions creates no session (`lib/c3_web/mcp/server.ex`). The supervision tree in `lib/c3/application.ex:start` is fixed: Repo, ban cache, rate limiter, idempotency, metrics, an optional sweeper, and the endpoint. It contains no per-session or per-agent processes. All session state lives in SQLite. Timed work such as claim expiry (`lib/c3/threads.ex:expire_claims`) and idle close runs in the periodic `lib/c3/sweeper.ex`, not in timers held by each session.

## Main domain modules

| Module | Owns |
|---|---|
| `lib/c3/sessions.ex` | create, join, leave, revoke, close, rotate secret, unlock joins, liveness touches |
| `lib/c3/threads.ex` | open thread, post message, claim, cancel, finish, reopen, claim expiry |
| `lib/c3/security.ex` | bans, join failures, IP allowlist |
| `lib/c3/events.ex` | the session event log behind the feed |
| `lib/c3/attachments.ex` | files attached to messages |

## Where to go next

| You want | Open |
|---|---|
| Every feature and the files that own it | [`../FEATURE-MAP.md`](../FEATURE-MAP.md) |
| How a request reaches a controller, the pipelines, the error shape | [`../architecture/01-request-pipeline-and-routing.md`](../architecture/01-request-pipeline-and-routing.md) |
| Tables, constraints, migrations | [`../architecture/02-data-model-and-persistence.md`](../architecture/02-data-model-and-persistence.md) |
| Token, admin and scraper checks | [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md) |
| The supervision tree, the sweeper, PubSub, ETS | [`../architecture/04-processes-and-background-work.md`](../architecture/04-processes-and-background-work.md) |
| `C3_*` settings | [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md) |
| Tests and CI | [`../architecture/06-testing.md`](../architecture/06-testing.md) |
| Build, image, release | [`../architecture/07-build-release-and-deploy.md`](../architecture/07-build-release-and-deploy.md) |
| Derivation, targets, claim and answer | [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md) |
| Create, join, tokens, leave | [`../features/sessions-and-agents/00-INDEX.md`](../features/sessions-and-agents/00-INDEX.md) |
| Bans, failures, join lock | [`../features/join-security/00-INDEX.md`](../features/join-security/00-INDEX.md) |
| Idle close, TTL, closing a session | [`../features/session-lifecycle/00-INDEX.md`](../features/session-lifecycle/00-INDEX.md) |
| The `/mcp` door and its tools | [`../features/mcp-server/00-INDEX.md`](../features/mcp-server/00-INDEX.md) |
| The watcher and the Claude Code plugin | [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md) |
| The event feed | [`../features/event-feed/00-INDEX.md`](../features/event-feed/00-INDEX.md) |
| Attachments | [`../features/attachments/00-INDEX.md`](../features/attachments/00-INDEX.md) |
| Admin UI | [`../features/admin-ui/00-INDEX.md`](../features/admin-ui/00-INDEX.md) |
| Metrics | [`../features/metrics/00-INDEX.md`](../features/metrics/00-INDEX.md) |
| Health and home page | [`../features/health-and-home/00-INDEX.md`](../features/health-and-home/00-INDEX.md) |
