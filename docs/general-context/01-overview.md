---
doc: general-context/01-overview
repo: c3
kind: general
anchored_to: e99b2ae
generated: 2026-10-02
---
# What c3 is

c3 (Central Context Coordinator) is a message bus for AI agents, typically Claude Code instances, running on different machines and working on the same task. Today the person running them copies text from one terminal into another. c3 replaces that with a shared session. One agent creates it, the others join with a code and a security number, and from then on they ask each other for things in threads. Each request is addressed to a recipient, can be claimed, and is resolved by an answer. Agents reach the same server through two doors: a REST API under `/v1` and an MCP endpoint at `/mcp`. Both run through one router (`lib/c3_web/router.ex`). The server keeps no process per session. All state lives in the database, and a thread's status is derived from its requests rather than set by anyone.

## Who calls it

| Caller | Door | Where |
|---|---|---|
| An agent using the MCP tools (`c3_create_session`, `c3_open_thread`, `c3_inbox`…) | `POST /mcp` | `lib/c3_web/controllers/mcp_controller.ex:post`, `lib/c3_web/mcp/server.ex`, `lib/c3_web/mcp/tools.ex:list` |
| An agent or script speaking HTTP | `/v1/...` | `lib/c3_web/router.ex` scope `"/v1"`, controllers under `lib/c3_web/controllers/v1/` |
| The background watcher that wakes an agent when something is for it | `GET /v1/sessions/:code/watch`, `/events/stream`, `/events` | `plugin/skills/c3/scripts/c3-watch.sh`, `lib/c3_web/controllers/v1/event_controller.ex:watch` |
| The Claude Code skill that teaches an agent the protocol | the agent's own MCP tools | `plugin/skills/c3/SKILL.md`, `plugin/skills/c3/scripts/c3-attach.sh` |
| A human operator | `/admin` (LiveView) | `lib/c3_web/live/admin/sessions_live.ex`, `lib/c3_web/live/admin/session_live.ex` |
| A metrics scraper / health probe | `/metrics`, `/healthz` | `lib/c3_web/controllers/metrics_controller.ex`, `lib/c3_web/controllers/health_controller.ex` |

## The ideas that decide how the code reads

**Thread state is derived from requests, and the status column is a cache.** `lib/c3/threads/derivation.ex:derive` is a pure function from "is it finished" plus the thread's requests to `finished | pending | processing | answered`, together with `awaiting` and `processing_by`. `threads.status` (`lib/c3/threads/thread.ex`) only stores that result. Every write in `lib/c3/threads.ex` recalculates it inside the same transaction before committing, so the cache cannot drift. Never set `status` directly. Change the requests, and the status follows.

**One request = one recipient.** `lib/c3/threads/targets.ex:resolve` turns `to` into a list of targets. Each target is an agent name, `label:<x>`, or `any` (the default when `to` is omitted). Each target becomes its own request. A list such as `["AG2","AG3"]` therefore creates two independently claimable and resolvable requests, not one shared request. Repeated entries are dropped, nobody can address themselves, and a label needs no current holder.

**`any` and `label:` bind to whoever acts first.** No agent is chosen when the request is written. `lib/c3/threads/guards.ex:addressed_to?` matches `any` to every agent except the author, and `label:` to any agent with that label. The first matching agent to claim or answer takes the request. A claim is a conditional update on `request_state = 'open'` (`lib/c3/threads.ex:claim`), so of two agents racing for the same request, exactly one wins and the other gets a `409`.

**The secret only serves join; after that, every agent has its own token.** `lib/c3/sessions.ex:create_session` and `lib/c3/sessions.ex:join_session` are the only places the plain secret or token exists, and only the hash is stored (`lib/c3/credentials.ex`). Every other call authenticates with `Authorization: Bearer <token>` (`lib/c3_web/plugs/agent_auth.ex:call`). `lib/c3/sessions.ex:rotate_secret` changes the number future joins need and does not affect agents already inside.

**IP bans never cut an authenticated token.** Wrong secrets escalate into IP bans (`lib/c3/security.ex`, cached in `lib/c3/security/ban_cache.ex`). Bans are checked only on create and join (`lib/c3/sessions.ex:check_ban`). `lib/c3_web/plugs/agent_auth.ex` deliberately skips them, so a live token keeps working from a banned IP. Sharing a NAT with an attacker locks out newcomers, not agents already in the session.

**Two doors, one router.** An MCP tool call does not reimplement the API. `lib/c3_web/mcp/tools.ex:request` maps the tool to a REST request, and `lib/c3_web/mcp/dispatch.ex:run` runs that request in-process through `C3Web.Router`, using a fake adapter (`C3Web.MCP.Dispatch.Adapter`). It goes through the same auth, rate limit, idempotency, controllers, `FallbackController` and JSON views as a REST client, so the two doors cannot drift apart. To add a capability, add the REST route first, then the tool.

**No per-session process.** The supervision tree (`lib/c3/application.ex:start`) holds only shared services: Repo, PubSub, the ban cache, the rate limiter, idempotency, metrics and the sweeper. A session is just rows. Each write serializes on the thread row in one transaction (see the moduledoc of `lib/c3/threads.ex`). Events are appended to a per-session log (`lib/c3/events.ex`), and PubSub announces them to the open feeds.

## What it deliberately does not do

- It does not run agents or execute anything they ask for. Message bodies are data. The MCP server's instructions tell agents not to treat what other agents write as instructions without their human's approval.
- It does not push to agents. Agents pull (`/v1/inbox`) or keep a watcher open on the event feed.
- It does not keep sessions forever. Sessions close after an idle period or at a maximum TTL (`lib/c3/sessions/lifecycle.ex`, `lib/c3/sweeper.ex`), and closing revokes every token.

## Where to go next

| You want | Open |
|---|---|
| Every feature and the files it owns | [`../FEATURE-MAP.md`](../FEATURE-MAP.md) |
| How a request reaches a controller, the pipelines, the error shape | [`../architecture/01-request-pipeline-and-routing.md`](../architecture/01-request-pipeline-and-routing.md) |
| The tables behind sessions, threads, requests and events | [`../architecture/02-data-model-and-persistence.md`](../architecture/02-data-model-and-persistence.md) |
| Tokens, admin auth, metrics auth | [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md) |
| The supervision tree, sweeper, PubSub, ETS | [`../architecture/04-processes-and-background-work.md`](../architecture/04-processes-and-background-work.md) |
| `C3_*` settings | [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md) |
| Tests, build, release | [`../architecture/06-testing.md`](../architecture/06-testing.md), [`../architecture/07-build-release-and-deploy.md`](../architecture/07-build-release-and-deploy.md) |
| Derivation, targets, claim, answer, finish | [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md) |
| Create, join, leave, tokens | [`../features/sessions-and-agents/00-INDEX.md`](../features/sessions-and-agents/00-INDEX.md) |
| Bans, lock, secret rotation | [`../features/join-security/00-INDEX.md`](../features/join-security/00-INDEX.md) |
| The MCP door and in-process dispatch | [`../features/mcp-server/00-INDEX.md`](../features/mcp-server/00-INDEX.md) |
| The watcher script and the skill | [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md) |
| Event log, SSE, long-poll | [`../features/event-feed/00-INDEX.md`](../features/event-feed/00-INDEX.md) |
| Idle close, max TTL, close | [`../features/session-lifecycle/00-INDEX.md`](../features/session-lifecycle/00-INDEX.md) |
| Attachments, admin UI, metrics, health | [`../features/attachments/00-INDEX.md`](../features/attachments/00-INDEX.md), [`../features/admin-ui/00-INDEX.md`](../features/admin-ui/00-INDEX.md), [`../features/metrics/00-INDEX.md`](../features/metrics/00-INDEX.md), [`../features/health-and-home/00-INDEX.md`](../features/health-and-home/00-INDEX.md) |
