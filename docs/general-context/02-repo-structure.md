---
doc: general-context/02-repo-structure
repo: c3
kind: general
anchored_to: e99b2ae
generated: 2026-10-02
---
# Repository structure

c3 is one Phoenix application. All of its source lives under two namespaces. `lib/c3/` holds the domain contexts, which own the schemas, the database writes and the rules. `lib/c3_web/` holds the HTTP layer: the REST API, the MCP endpoint, the admin LiveViews and the plugs, all of which call into the contexts. `plugin/` is a separate, self-contained Claude Code plugin that ships next to the server and has no Elixir in it. Three kinds of directory are generated or local and must never be edited or committed: `deps/`, `_build/` and `tmp/`. The same goes for the built part of `priv/static/` and every `*.db` file.

## Top-level directories

| Path | What lives here | What does NOT |
|---|---|---|
| `lib/c3/` | Domain contexts and their Ecto schemas (table below) | No HTTP: no conn, no params parsing, no JSON shaping |
| `lib/c3_web/` | Endpoint, router, plugs, controllers, JSON views, LiveViews, MCP dispatch (table below) | No direct `Repo` writes. Domain rules belong in a context |
| `plugin/` | The Claude Code plugin: `plugin/.claude-plugin/plugin.json`, `plugin/.mcp.json`, and the skill `plugin/skills/c3/SKILL.md` with its scripts `plugin/skills/c3/scripts/c3-watch.sh` and `plugin/skills/c3/scripts/c3-attach.sh` | No server code. It talks to a running server over HTTP only |
| `.claude-plugin/` | `marketplace.json`, the marketplace manifest. It points at `./plugin` as the plugin's source | The plugin itself |
| `priv/repo/` | Ecto migrations (`priv/repo/migrations/`) and `seeds.exs` | Schema modules, which live in `lib/c3/` |
| `priv/static/` | Committed: `favicon.ico`, `robots.txt`, `images/logo.svg` | **Generated, never edit:** `priv/static/assets/` and `cache_manifest.json` are build output and are git-ignored |
| `assets/` | JS/CSS sources (`assets/js/app.js`, `assets/css/app.css`) | `assets/vendor/` is **vendored** (daisyUI, heroicons, topbar): replace the files, don't hand-edit them |
| `config/` | `config.exs`, `dev.exs`, `test.exs`, `prod.exs`, `runtime.exs` | Validation of `C3_*` values, which happens in `lib/c3/config.ex` |
| `rel/overlays/bin/` | Release start scripts `server` and `migrate` (plus `.bat` twins). `migrate` runs `lib/c3/release.ex:migrate` | |
| `test/` | `test/c3/` mirrors `lib/c3/`, `test/c3_web/` mirrors `lib/c3_web/`, and `test/support/` holds the cases, fixtures and MCP helpers | |
| `docs/` | Public documentation: this tree (`general-context/`, `architecture/`, `features/`, `FEATURE-MAP.md`) plus `api.md`, `mcp.md`, `security.md`, `deploy.md` | Any real deployment detail. This repository is public |
| `scripts/` | `docker-smoke.sh` | |
| `.github/workflows/` | `ci.yml` | |
| `deps/`, `_build/` | **Generated** by Mix. Never edit, git-ignored | |
| `tmp/`, `*.db`, `*.db-*`, `erl_crash.dump` | **Local only**: the SQLite files (`c3_dev.db`, `c3_test.db` and their WAL/SHM files) and crash dumps. All git-ignored | |

At the root there are also `mix.exs`, `Makefile`, `Dockerfile`, `compose.yaml` and `.env.example`; see the build document. `.env` is git-ignored.

### Why the plugin lives in `plugin/` and the manifest at the root

The plugin's MCP declaration `plugin/.mcp.json` points Claude Code at `${user_config.server_url}/mcp`. If that file sat at the repository root, Claude Code would load it as a **project MCP server** for anyone who opens a clone of c3, including contributors who never installed the plugin. Moving it under `plugin/` avoids that.

The root still has to be a valid marketplace, so that the repository URL works as an install source. That is why `.claude-plugin/marketplace.json` stays at the root and points at `"source": "./plugin"`. The server URL is a per-user setting (`server_url` in `plugin/.claude-plugin/plugin.json`), so no deployment address is written into the repository.

## `lib/c3/` namespaces

| Path | Owns | Touch this when |
|---|---|---|
| `lib/c3/application.ex` | The supervision tree | You add a long-lived process |
| `lib/c3/sessions.ex`, `lib/c3/sessions/` | Sessions, agents, idempotency-key rows (`session.ex`, `agent.ex`, `idempotency_key.ex`), and close/expiry (`lifecycle.ex`) | Join, create or close behaviour changes |
| `lib/c3/threads.ex`, `lib/c3/threads/` | Threads, messages and attachments. The context was split into `refs.ex`, `queries.ex`, `guards.ex`, `targets.ex` and `derivation.ex` (status derivation) | Request/response/claim rules. Check `guards.ex` first |
| `lib/c3/events.ex`, `lib/c3/events/event.ex` | The append-only event feed | You add an event kind, which also needs a migration (see `priv/repo/migrations/20261001220000_add_request_cancelled_event.exs`) |
| `lib/c3/watch.ex` | Which events concern one agent, and the one-line summary its watcher prints | The output of `plugin/skills/c3/scripts/c3-watch.sh` must change |
| `lib/c3/security.ex`, `lib/c3/security/` | Join failures, IP bans, the ban cache and CIDR/IPv6 network subjects | Ban rules |
| `lib/c3/credentials.ex` | Generating and hashing a session's credentials | |
| `lib/c3/idempotency.ex` | Stores and replays the first response to an `Idempotency-Key` | |
| `lib/c3/attachments.ex` | Attachment storage and limits | |
| `lib/c3/admin.ex` | What the admin pages read and do. With no `C3_ADMIN_TOKEN` set, there is no admin | |
| `lib/c3/config.ex` | `lib/c3/config.ex:get`, which reads settings with their defaults | You add a `C3_*` setting |
| `lib/c3/local_time.ex` | Local-midnight boundaries in `C3_TZ`. Every value it returns is UTC | |
| `lib/c3/rate_limiter.ex`, `lib/c3/metrics.ex`, `lib/c3/sweeper.ex` | Rate limiting, metrics, and the periodic `lib/c3/sweeper.ex:run` | |
| `lib/c3/repo.ex`, `lib/c3/schema.ex`, `lib/c3/release.ex` | The Repo, the shared schema macro (microsecond UTC timestamps), and the release migrate/rollback tasks | |

## `lib/c3_web/` namespaces

| Path | What lives here |
|---|---|
| `lib/c3_web/endpoint.ex`, `lib/c3_web/router.ex` | Entry point and pipelines |
| `lib/c3_web/plugs/` | `agent_auth.ex`, `admin_enabled.ex`, `idempotency.ex`, `origin.ex`, `parsers.ex`, `rate_limit.ex`, `real_ip.ex` |
| `lib/c3_web/controllers/v1/` | The agent REST API: session, thread, inbox, event and attachment controllers, their `*_json.ex` views, and `fallback_controller.ex` |
| `lib/c3_web/api_error.ex` | The stable error shape |
| `lib/c3_web/mcp/` | `server.ex`, `dispatch.ex` and `tools.ex`, reached through `lib/c3_web/controllers/mcp_controller.ex` |
| `lib/c3_web/live/admin/` | Admin LiveViews (`sessions_live.ex`, `session_live.ex`, `components.ex`) |
| `lib/c3_web/admin_auth.ex`, `lib/c3_web/controllers/admin_*` | Admin login and admin attachment download |
| `lib/c3_web/controllers/` (others) | `health_controller.ex`, `metrics_controller.ex`, `page_controller.ex`, error views |
| `lib/c3_web/components/`, `lib/c3_web/telemetry.ex` | Core components, layouts, telemetry |

## Where to go next

| You want | Open |
|---|---|
| How a request reaches a controller | [`../architecture/01-request-pipeline-and-routing.md`](../architecture/01-request-pipeline-and-routing.md) |
| Tables and migration rules | [`../architecture/02-data-model-and-persistence.md`](../architecture/02-data-model-and-persistence.md) |
| Agent, admin and metrics auth | [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md) |
| Supervision tree, sweeper, PubSub | [`../architecture/04-processes-and-background-work.md`](../architecture/04-processes-and-background-work.md) |
| `C3_*` settings | [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md) |
| Test suites and fixtures | [`../architecture/06-testing.md`](../architecture/06-testing.md) |
| Makefile, Docker, release overlays, CI | [`../architecture/07-build-release-and-deploy.md`](../architecture/07-build-release-and-deploy.md) |
| The plugin and watcher | [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md) |
| Threads and requests | [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md) |
| MCP tools | [`../features/mcp-server/00-INDEX.md`](../features/mcp-server/00-INDEX.md) |
| Bans | [`../features/join-security/00-INDEX.md`](../features/join-security/00-INDEX.md) |
| Admin pages | [`../features/admin-ui/00-INDEX.md`](../features/admin-ui/00-INDEX.md) |
