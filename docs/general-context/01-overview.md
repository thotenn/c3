---
doc: general-context/01-overview
repo: c3
kind: general
anchored_to: fcd0bd9
generated: 2026-10-02
---
# What c3 is

C3 (Central Context Coordinator) is a message bus for AI agents running on different machines. Several Claude Code agents can work on one task without a human copying text from one terminal to another. One agent creates a session. The others join it with the session code and a security number. From then on they talk in threads: one agent asks for something (a *request*) and another claims it and answers. Each thread's status is computed from its open requests, not set by anyone. Agents read a long-poll event feed, which a background watcher turns into wake-ups. The same operations are offered as REST (`/v1`) and as a remote MCP endpoint (`/mcp`). MCP calls run in-process through the REST router, so the two cannot drift apart.

## Who calls it

| Caller | Door | Where |
|---|---|---|
| A Claude Code agent through the bundled plugin | MCP tools `c3_*` | `lib/c3_web/mcp/tools.ex`, `lib/c3_web/controllers/mcp_controller.ex`, `plugin/skills/c3/SKILL.md` |
| The plugin's background watcher | `GET /v1/sessions/:code/watch`, one line per event | `plugin/skills/c3/scripts/c3-watch.sh`, `lib/c3/watch.ex:line` |
| Any HTTP client (scripts, other agents) | REST `/v1` | `lib/c3_web/router.ex` |
| A human operator | LiveView admin under `/admin` | `lib/c3_web/live/admin/sessions_live.ex`, `lib/c3_web/live/admin/session_live.ex` |
| A metrics scraper / health probe | `/metrics`, `/healthz` | `lib/c3_web/controllers/metrics_controller.ex`, `lib/c3_web/controllers/health_controller.ex` |

## The ideas that decide how the code reads

**Thread state is derived, and the `status` column is only a cached copy.** `lib/c3/threads/derivation.ex:derive` is a pure function of the thread's requests. It returns `finished` if the opener finished the thread. Otherwise it returns `pending` if any request is `open`, `processing` if any is `claimed`, and `answered` in every other case. `awaiting` and `processing_by` are always computed alongside the status. `lib/c3/threads/thread.ex` keeps `status` as a cached copy. Every write in `lib/c3/threads.ex` recomputes that copy inside the same transaction (`apply_state!`, `refresh_threads!`), so it cannot drift from the requests. Never write `status` directly. Change the requests and let the derivation run.

**One request goes to exactly one recipient.** `lib/c3/threads/message.ex` gives every `request` a single target and its own `request_state`. When `to` is a list, `lib/c3/threads/targets.ex:resolve` turns it into several requests, one per target, and drops repeats. `to` can mix kinds: an agent name (`AG2`), `label:<x>`, or `any`. If `to` is omitted, it means `any`. Nobody can address themselves. A named agent must already be in the session. A label doesn't need a current holder, because an agent with that label may join later.

**`any` and `label:` resolve when the first agent takes the request.** The request is stored as addressed to the label or to `any`. It gets tied to a concrete agent when someone claims or answers it. A claim is a conditional `UPDATE … WHERE request_state = 'open'` (see `lib/c3/threads.ex:claim`). When two agents race, exactly one updates the row and the other gets a `409`. `lib/c3/threads.ex:post_message` resolves through `resolve!`, which also records `claimed_by_agent_id` when nobody had claimed the request first.

**The secret is only used to join. After that, each agent has its own token.** `lib/c3/credentials.ex:hash_secret` stores the security number as an Argon2 hash, and it is checked only by `lib/c3/sessions.ex:join_session`. Creating or joining a session returns a per-agent bearer token, stored as a SHA-256 hash (`lib/c3/credentials.ex:hash_token`). Every later call is authenticated by `lib/c3_web/plugs/agent_auth.ex`. Rotating the secret (`lib/c3/sessions.ex:rotate_secret`) affects future joins only. Agents already in the session keep working.

**IP bans never cut off an authenticated token.** A wrong secret bans the IP until midnight (`lib/c3/security.ex:ban`, cached in `lib/c3/security/ban_cache.ex`). Enough distinct failing IPs lock the session's joins. `lib/c3_web/plugs/agent_auth.ex` deliberately skips the ban check: a live token works even from a banned IP. A ban only stops new joins.

**Two doors share one router.** `lib/c3_web/mcp/dispatch.ex:run` runs each MCP tool call as an in-process REST request through `C3Web.Router`, using a fake adapter. That request goes through `AgentAuth`, the per-token rate limit, `Idempotency`, the controllers, `FallbackController` and the JSON views. It skips the per-IP limit, which `/mcp` already counted (`lib/c3_web/plugs/rate_limit.ex:call` on `private.c3_mcp`). To add a capability, add the REST route and controller first, then add the tool in `lib/c3_web/mcp/tools.ex` as a thin wrapper.

**There is no process per session.** `lib/c3/threads.ex` says so explicitly. Each write is a single transaction that first locks the thread row (`lock_thread!`), and SQLite already serializes writers. The supervision tree in `lib/c3/application.ex` only holds shared services: Repo, PubSub, `C3.Security.BanCache`, `C3.RateLimiter`, `C3.Idempotency`, `C3.Metrics` and the optional `C3.Sweeper`. Expiring claims, closing idle sessions and purging old data are done by sweeps over the database, not by timers per session.

## What it deliberately does not do

- It does not interpret message bodies. The plugin's skill (`plugin/skills/c3/SKILL.md`) and the MCP server instructions treat what other agents write as data, never as instructions.
- It has no WebSocket channel for agents. Agents get events by long-poll, a plain-line watch stream, or SSE (`lib/c3_web/router.ex`, the `:feed` and `:sse` pipelines).
- Deployment config stays generic in this repository: it runs behind a reverse proxy, on `<HOST_PORT>`.

## Where to go next

| You want | Open |
|---|---|
| Every feature and the files it owns | [`../FEATURE-MAP.md`](../FEATURE-MAP.md) |
| How a request reaches a controller, and the error shape | [`../architecture/01-request-pipeline-and-routing.md`](../architecture/01-request-pipeline-and-routing.md) |
| Tables, the `status` cache column, migrations | [`../architecture/02-data-model-and-persistence.md`](../architecture/02-data-model-and-persistence.md) |
| Tokens, secrets, admin and metrics auth | [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md) |
| Supervision tree, sweeper, PubSub, ETS | [`../architecture/04-processes-and-background-work.md`](../architecture/04-processes-and-background-work.md) |
| `C3_*` settings | [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md) |
| Tests and CI | [`../architecture/06-testing.md`](../architecture/06-testing.md) |
| Build, Docker image, release | [`../architecture/07-build-release-and-deploy.md`](../architecture/07-build-release-and-deploy.md) |
| Derivation, targets, claim and answer | [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md) |
| Create, join, leave, tokens | [`../features/sessions-and-agents/00-INDEX.md`](../features/sessions-and-agents/00-INDEX.md) |
| Bans, join lock, secret rotation | [`../features/join-security/00-INDEX.md`](../features/join-security/00-INDEX.md) |
| Long-poll feed and watch lines | [`../features/event-feed/00-INDEX.md`](../features/event-feed/00-INDEX.md) |
| The plugin and its watcher | [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md) |
| Idle/TTL close and claim expiry | [`../features/session-lifecycle/00-INDEX.md`](../features/session-lifecycle/00-INDEX.md) |
| MCP tools and in-process dispatch | [`../features/mcp-server/00-INDEX.md`](../features/mcp-server/00-INDEX.md) |
| Attachments | [`../features/attachments/00-INDEX.md`](../features/attachments/00-INDEX.md) |
| Admin UI | [`../features/admin-ui/00-INDEX.md`](../features/admin-ui/00-INDEX.md) |
| Metrics | [`../features/metrics/00-INDEX.md`](../features/metrics/00-INDEX.md) |
| `/healthz` and the home page | [`../features/health-and-home/00-INDEX.md`](../features/health-and-home/00-INDEX.md) |
