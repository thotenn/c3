---
doc: general-context/02-repo-structure
repo: c3
kind: general
anchored_to: fa64fbd
generated: 2026-10-02
---
# Repository structure

c3 is one Phoenix application with two code namespaces. `lib/c3/` holds the domain: sessions, threads, security and the supervised processes. `lib/c3_web/` holds the HTTP layer: the REST API under `v1`, the MCP endpoint, the admin LiveViews and the plugs. `plugin/` is a separate deliverable, the Claude Code plugin, and none of the Elixir code depends on it. Edit only code under `lib/`, `plugin/`, `priv/repo/`, `config/`, `rel/`, `test/` and `assets/`. Everything under `deps/`, `_build/`, `priv/static/assets/` and `tmp/`, and every `*.db*` file, is generated or downloaded.

## Top-level directories

| Path | What lives here | What does NOT |
|---|---|---|
| `lib/c3/` | Domain contexts, Ecto schemas, the Repo and the supervised workers. Their start order is in `lib/c3/application.ex:C3.Application`. | Anything that knows about HTTP, `conn` or JSON shapes |
| `lib/c3_web/` | Endpoint, router, plugs, controllers and JSON views, the MCP server and the admin LiveViews | Business rules. Controllers call into `lib/c3/` contexts and do not write to the Repo themselves. |
| `plugin/` | The Claude Code plugin: `plugin/.claude-plugin/plugin.json`, `plugin/.mcp.json`, `plugin/skills/c3/SKILL.md` and the scripts `plugin/skills/c3/scripts/c3-watch.sh` and `plugin/skills/c3/scripts/c3-attach.sh` | Elixir code. The server does not read this folder. |
| `.claude-plugin/` (root) | Only `marketplace.json`, which points `source` at `./plugin` | The plugin itself |
| `priv/repo/` | Migrations in `priv/repo/migrations/` and `seeds.exs` | Schema docs (see architecture 02) |
| `priv/static/` | favicon, images, `robots.txt` | `priv/static/assets/` is build output from tailwind and esbuild, git-ignored. Never edit it. |
| `assets/` | CSS/JS sources. `assets/vendor/` holds vendored daisyUI, heroicons and topbar. | Treat `assets/vendor/` as vendored: replace it, do not patch it. |
| `config/` | `config.exs`, `dev.exs`, `test.exs`, `prod.exs`, `runtime.exs` | Validation of `C3_*` values, which lives in `lib/c3/config.ex:C3.Config` |
| `rel/overlays/bin/` | Release scripts `server` and `migrate`, each with a `.bat` twin | Migration logic, which lives in `lib/c3/release.ex:C3.Release` |
| `test/` | `test/c3/` and `test/c3_web/` mirror `lib/`. Helpers are in `test/support/` (`conn_case.ex`, `data_case.ex`, `fixtures/c3_fixtures.ex`, `mcp_helpers.ex`). | Plugin tests are not under `test/plugin` (absent). The shell scripts are tested from `test/c3/watch_script_test.exs` and `test/c3/attach_script_test.exs`. |
| `docs/` | Public software docs: `api.md`, `mcp.md`, `deploy.md` and this context tree | Real deployment values |
| `scripts/` | `docker-smoke.sh` | |
| `.github/workflows/` | `ci.yml` | |
| `deps/`, `_build/`, `tmp/`, `cover/` | Generated (git-ignored) | Never edit |
| `c3_dev.db`, `c3_test.db*`, `erl_crash.dump` | Local runtime files (git-ignored via `*.db`, `*.db-*`) | Never commit. Delete them to reset local state. |

## `lib/c3/` namespaces

| Path | What lives here | Touch this when |
|---|---|---|
| `lib/c3/sessions.ex`, `lib/c3/sessions/` | Session and agent schemas (`session.ex`, `agent.ex`), `lifecycle.ex`, `idempotency_key.ex` | You change join, leave, close or agent identity |
| `lib/c3/threads.ex`, `lib/c3/threads/` | Thread, message and attachment schemas. `refs.ex`, `queries.ex` and `guards.ex` were split out of `C3.Threads` at the anchor commit. `derivation.ex` derives thread status. `targets.ex` resolves recipients. | You change requests, responses, claims or status rules. Look in the split modules before you grow `threads.ex`. |
| `lib/c3/events.ex`, `lib/c3/events/event.ex` | The append-only event log | You add an event kind (that needs a migration, see `priv/repo/migrations/20261002120100_add_secret_rotated_event.exs`) |
| `lib/c3/security.ex`, `lib/c3/security/` | Join failures, IP bans, `ban_cache.ex`, `cidr.ex` | You change join brute-force protection |
| `lib/c3/attachments.ex` | Attachment storage | |
| `lib/c3/credentials.ex` | Token and secret generation and checks | |
| `lib/c3/admin.ex` | Queries for the admin UI | |
| `lib/c3/config.ex`, `lib/c3/release.ex` | Runtime settings with `validate!` at boot; migrate-in-release | |
| `lib/c3/sweeper.ex`, `lib/c3/rate_limiter.ex`, `lib/c3/idempotency.ex`, `lib/c3/metrics.ex`, `lib/c3/watch.ex` | Supervised processes and ETS-backed caches. `C3.Sweeper` starts only when `C3.Config.get(:sweeper)` is truthy (`lib/c3/application.ex:C3.Application`). | |
| `lib/c3/repo.ex`, `lib/c3/schema.ex`, `lib/c3/local_time.ex` | Repo, the shared schema macro, time helpers | |

## `lib/c3_web/` namespaces

| Path | What lives here |
|---|---|
| `lib/c3_web/endpoint.ex`, `lib/c3_web/router.ex`, `lib/c3_web.ex` | Entry point and pipelines. `C3Web` defines the `use C3Web, :controller \| :html \| :live_view` macros. |
| `lib/c3_web/plugs/` | `agent_auth.ex`, `admin_enabled.ex`, `rate_limit.ex`, `real_ip.ex`, `origin.ex`, `idempotency.ex`, `parsers.ex` |
| `lib/c3_web/controllers/v1/` | The agent REST API: session, thread, inbox, event and attachment controllers plus `*_json.ex` views. `fallback_controller.ex` maps errors through `lib/c3_web/api_error.ex`. |
| `lib/c3_web/mcp/` | `server.ex`, `dispatch.ex` and `tools.ex`, reached via `lib/c3_web/controllers/mcp_controller.ex` |
| `lib/c3_web/live/admin/` | `sessions_live.ex`, `session_live.ex`, `components.ex` |
| `lib/c3_web/controllers/` (root) | health, metrics, page (home), admin session login and admin attachment download, error views |
| `lib/c3_web/admin_auth.ex`, `lib/c3_web/telemetry.ex`, `lib/c3_web/components/` | Admin auth helpers, telemetry supervisor, core components and layouts |

## Why the plugin is in `plugin/` and the marketplace manifest is at the root

`plugin/.mcp.json` declares an HTTP MCP server at `${user_config.server_url}/mcp`. That URL is filled from the `server_url` user setting in `plugin/.claude-plugin/plugin.json`. Claude Code loads any `.mcp.json` at a repository's root as a project MCP server. If this file sat at the root, everyone who opens the c3 repo in Claude Code would be offered the server, with an unresolved placeholder in the URL. So the plugin lives in a subfolder. Only the marketplace manifest `.claude-plugin/marketplace.json` sits at the root, with `"source": "./plugin"`, which lets `claude plugin marketplace add` work against this repository. When you change the plugin, bump `version` in `plugin/.claude-plugin/plugin.json`.

## Where to go next

| You want | Open |
|---|---|
| How a request reaches a controller | [`../architecture/01-request-pipeline-and-routing.md`](../architecture/01-request-pipeline-and-routing.md) |
| Tables, migrations, Repo rules | [`../architecture/02-data-model-and-persistence.md`](../architecture/02-data-model-and-persistence.md) |
| Agent/admin/metrics auth | [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md) |
| Supervision tree, sweeper, ETS | [`../architecture/04-processes-and-background-work.md`](../architecture/04-processes-and-background-work.md) |
| `C3_*` settings | [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md) |
| Test suites and helpers | [`../architecture/06-testing.md`](../architecture/06-testing.md) |
| Makefile, Docker, release overlays, CI | [`../architecture/07-build-release-and-deploy.md`](../architecture/07-build-release-and-deploy.md) |
| The plugin and watcher | [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md) |
| Threads and requests | [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md) |
| MCP server | [`../features/mcp-server/00-INDEX.md`](../features/mcp-server/00-INDEX.md) |
| Admin UI | [`../features/admin-ui/00-INDEX.md`](../features/admin-ui/00-INDEX.md) |
