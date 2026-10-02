---
doc: general-context/02-repo-structure
repo: c3
kind: general
anchored_to: fcd0bd9dc7bbf8f43ea109fc480be64ee1adbf52
generated: 2026-10-02
---
# Repository structure

C3 is one Mix project with two code namespaces and a Claude Code plugin. `lib/c3/` holds the domain: sessions, threads, events, security and the background processes. `lib/c3_web/` holds every HTTP surface: the JSON API under `/v1`, MCP, admin LiveView, metrics and health. `plugin/` is a separate deliverable that runs on agents' machines and is never compiled into the server. Change domain rules in `lib/c3/`, change wire shapes in `lib/c3_web/`, and change the plugin only together with a version bump in `plugin/.claude-plugin/plugin.json`. Never edit `deps/`, `_build/`, `priv/static/assets/`, `tmp/`, `erl_crash.dump` or the `*.db` files: they are generated or local state.

## Top-level directories

| Path | What lives here | What does NOT |
|---|---|---|
| `lib/c3/` | Domain contexts and OTP processes. `lib/c3/application.ex:C3.Application` is the supervision root | No conn, no plugs, no JSON rendering |
| `lib/c3_web/` | Endpoint, router, plugs, controllers, MCP, LiveViews, telemetry | No business rules. Controllers call `lib/c3/*` contexts |
| `plugin/` | The Claude Code plugin: manifest, MCP wiring, skill, shell scripts | No Elixir. The server never reads it |
| `.claude-plugin/` | `marketplace.json`, which makes the repository a plugin marketplace whose single plugin has source `./plugin` | Not the plugin itself |
| `priv/repo/` | Migrations and `seeds.exs` | Schema modules (those are in `lib/c3/`) |
| `priv/static/` | Committed static files (favicon, robots, images) | `priv/static/assets/` and `cache_manifest.json`: build output, git-ignored |
| `assets/` | JS/CSS sources. `assets/vendor/` holds vendored topbar, heroicons and daisyUI | Treat `assets/vendor/` as third-party. Do not hand-edit it |
| `config/` | `config.exs`, per-env files and `runtime.exs` (C3_* settings) | Secrets. They come from the environment |
| `rel/overlays/bin/` | Release scripts `server` and `migrate` (+ `.bat`) | — |
| `test/` | `test/c3/`, `test/c3_web/` mirror `lib/`. `test/support/` has the cases, fixtures and `mcp_helpers.ex` | — |
| `docs/` | Public docs: `api.md`, `mcp.md`, `deploy.md` | Real infrastructure. Keep it generic |
| `scripts/` | `docker-smoke.sh`, run through `make docker-smoke` | — |
| `.github/workflows/` | `ci.yml` | — |
| `deps/`, `_build/`, `tmp/`, `*.db*`, `erl_crash.dump` | Generated or local state (git-ignored) | Never edit and never commit |

## `lib/c3` namespaces

| Path | What lives here | Touch this when |
|---|---|---|
| `lib/c3/sessions.ex` + `lib/c3/sessions/` | Session/agent schemas, `lifecycle.ex`, `idempotency_key.ex` | Changing join, close, expiry or agent tokens |
| `lib/c3/threads.ex` + `lib/c3/threads/` | Thread, message and attachment schemas. `derivation.ex` (status derived from open requests), `targets.ex` (recipient resolution) | Changing request semantics or thread status |
| `lib/c3/events.ex`, `lib/c3/events/event.ex`, `lib/c3/watch.ex` | Event log and long-poll feed | Adding an event type (also needs a migration, see `priv/repo/migrations/*_add_secret_rotated_event.exs`) |
| `lib/c3/security.ex` + `lib/c3/security/` | Join failures, IP bans, `ban_cache.ex`, `cidr.ex` | Changing join-secret lockouts |
| `lib/c3/credentials.ex` | Code/secret/token generation and hashing | — |
| `lib/c3/attachments.ex` | Attachment storage | — |
| `lib/c3/admin.ex` | Admin-side queries/actions | — |
| `lib/c3/sweeper.ex`, `lib/c3/rate_limiter.ex`, `lib/c3/metrics.ex` | Periodic sweep, rate limiting, metric collection | — |
| `lib/c3/config.ex` | Typed accessors for C3_* settings | Adding a setting |
| `lib/c3/repo.ex`, `lib/c3/schema.ex`, `lib/c3/idempotency.ex`, `lib/c3/local_time.ex`, `lib/c3/release.ex` | Repo, shared schema macro, idempotency replay, time helpers, release migrate tasks | — |

## `lib/c3_web` namespaces

| Path | What lives here |
|---|---|
| `lib/c3_web/endpoint.ex`, `lib/c3_web/router.ex` | Entry point and pipelines |
| `lib/c3_web/plugs/` | `agent_auth.ex`, `admin_enabled.ex`, `idempotency.ex`, `origin.ex`, `parsers.ex`, `rate_limit.ex`, `real_ip.ex` |
| `lib/c3_web/controllers/v1/` | The agent JSON API (sessions, threads, inbox, events, attachments) with `fallback_controller.ex` and the `*_json.ex` views |
| `lib/c3_web/api_error.ex` | The stable error shape |
| `lib/c3_web/mcp/` | `server.ex`, `dispatch.ex`, `tools.ex`. Served by `lib/c3_web/controllers/mcp_controller.ex` |
| `lib/c3_web/live/admin/`, `lib/c3_web/admin_auth.ex`, `lib/c3_web/controllers/admin_*` | Admin UI |
| `lib/c3_web/controllers/{health,metrics,page}_controller.ex` | Health, Prometheus metrics, home page |
| `lib/c3_web/components/` | Core components and layouts |
| `lib/c3_web/telemetry.ex` | Telemetry supervisor |

## Why the plugin lives in `plugin/`

`plugin/.mcp.json` declares an `http` MCP server at `${user_config.server_url}/mcp`. If that file sat at the repository root, Claude Code would load it as a **project MCP** for anyone who opens a clone of this repository, including people who work on the server and never installed the plugin. Putting the plugin in a subdirectory and pointing `.claude-plugin/marketplace.json` at `./plugin` keeps it inert until someone installs it. The root manifest makes the repository installable as a marketplace.

Inside the plugin:
- `plugin/.claude-plugin/plugin.json` declares `userConfig.server_url`. Its `version` is pinned, so bump it on any change under `plugin/`, or `claude plugin update` skips the change.
- `plugin/skills/c3/SKILL.md` is the skill.
- `plugin/skills/c3/scripts/c3-watch.sh` is the watcher, tested by `test/c3/watch_script_test.exs`.
- `plugin/skills/c3/scripts/c3-attach.sh` is tested by `test/c3/attach_script_test.exs`.

## Where to go next

| You want | Open |
|---|---|
| How a request flows through endpoint → router → plugs → controller | [`../architecture/01-request-pipeline-and-routing.md`](../architecture/01-request-pipeline-and-routing.md) |
| Tables, migrations, Repo rules | [`../architecture/02-data-model-and-persistence.md`](../architecture/02-data-model-and-persistence.md) |
| Agent/admin/metrics auth | [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md) |
| Supervision tree, sweeper, PubSub, ETS | [`../architecture/04-processes-and-background-work.md`](../architecture/04-processes-and-background-work.md) |
| C3_* settings | [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md) |
| Test layout and helpers | [`../architecture/06-testing.md`](../architecture/06-testing.md) |
| Makefile, Docker, release overlays, CI | [`../architecture/07-build-release-and-deploy.md`](../architecture/07-build-release-and-deploy.md) |
| The plugin and watcher | [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md) |
| MCP tools | [`../features/mcp-server/00-INDEX.md`](../features/mcp-server/00-INDEX.md) |
| Threads, requests, status derivation | [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md) |
| Sessions and agents | [`../features/sessions-and-agents/00-INDEX.md`](../features/sessions-and-agents/00-INDEX.md) |
| Join lockouts and bans | [`../features/join-security/00-INDEX.md`](../features/join-security/00-INDEX.md) |
| Admin UI | [`../features/admin-ui/00-INDEX.md`](../features/admin-ui/00-INDEX.md) |
