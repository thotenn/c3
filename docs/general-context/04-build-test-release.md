---
doc: general-context/04-build-test-release
repo: c3
kind: general
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Build, test and release

Run every command through the `Makefile`. Type `make` to list the targets. A change is done when two commands pass: `make precommit` (compile with warnings as errors, unlock unused deps, format, test) and `make docker-smoke` (build the image, boot a throwaway container, wait for `/healthz` → 200). CI runs both. `precommit` formats files in place, and CI fails when the tree has a diff afterwards. So commit the formatted result, not the version from before formatting. A change under `plugin/` also needs a version bump in `plugin/.claude-plugin/plugin.json` and `make plugin-validate`.

## The commands

| Command | What it runs | Needs | Trap |
|---|---|---|---|
| `make setup` | `mix setup` = `deps.get`, `ecto.setup` (create, migrate, seeds), `assets.setup`, `assets.build` | Erlang/Elixir from `.tool-versions` | Downloads the tailwind/esbuild binaries if they are missing |
| `make dev` | `iex -S mix phx.server` | `make setup` once | Listens on the dev port (default 4000) |
| `make test` | `mix test`; the alias first runs `ecto.create --quiet` and `ecto.migrate --quiet` | none | The test DB is migrated on every run, so a broken migration fails every test |
| `make precommit` | `mix precommit` = `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test` (in `MIX_ENV=test` via `preferred_envs`) | none | **Rewrites files.** CI runs `git diff --exit-code` right after it |
| `make fmt` | `mix format` | none | none |
| `make secret` | `mix phx.gen.secret` | none | Prints a fresh `SECRET_KEY_BASE` |
| `make test-watcher` | Only the `/watch` controller test and the plugin script tests (watch, attach) | `sh` and `curl` on the PATH | These tests shell out to the real scripts in `plugin/skills/c3/scripts/` |
| `make plugin-validate` | `claude plugin validate .` and `claude plugin validate ./plugin` | the `claude` CLI | Validates the marketplace at the repo root and the plugin itself |
| `make docker-build` | `$(DOCKER) build -t c3:latest .` | docker, or podman (detected automatically) | Override with `DOCKER=` / `IMAGE=` |
| `make docker-smoke` | `docker-build`, then `scripts/docker-smoke.sh` | docker/podman, curl, free local `PORT` (default 4000) | Binds to loopback only; gives up after 30 s and prints the container logs |
| `make docker-up` / `docker-down` / `docker-logs` | `docker compose` stack | a `.env` file | `down` keeps the data volume |
| `make dist` | `git archive` of HEAD → `c3-<version>.tar.gz` | a clean tree | Takes the version from `mix.exs`; refuses to run with uncommitted changes |

## What the smoke test proves

`scripts/docker-smoke.sh` starts the image with a random `SECRET_KEY_BASE` and `PHX_HOST=localhost`, then polls `/healthz`. That route is served by `lib/c3_web/controllers/health_controller.ex:show` and wired in `lib/c3_web/router.ex:/healthz`. The image's command runs `bin/migrate` and then `bin/server`:

1. `bin/migrate` runs `c3 eval C3.Release.migrate` → `lib/c3/release.ex:migrate`, which runs every migration on a single connection (`pool_size: 1`). With a pool, the connections race to switch a fresh SQLite file to WAL and log `database is locked`.
2. `bin/server` sets `PHX_SERVER=true` and runs `c3 start`.
3. The supervision tree boots from `lib/c3/application.ex` (see [`../architecture/04-processes-and-background-work.md`](../architecture/04-processes-and-background-work.md)).
4. `/healthz` answers 200, and the script exits 0.

So a green smoke test means the release compiles, the migrations apply to an empty database, and the runtime config validates at boot. That runtime config is read in `lib/c3/config.ex`; see [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md). Run `make docker-smoke` whenever you touch the Dockerfile, `rel/`, runtime config or migrations. Rollback is `lib/c3/release.ex:rollback`; no make target wraps it.

## Plugin changes

The plugin is `plugin/.claude-plugin/plugin.json` plus the skill in `plugin/skills/c3/SKILL.md` and its scripts (`plugin/skills/c3/scripts/c3-watch.sh`, `plugin/skills/c3/scripts/c3-attach.sh`). Its `version` is pinned, so `claude plugin update` skips a change unless the version is bumped. Keep the plugin version equal to the `mix.exs` version of the release that ships it. Before calling a plugin change done, run `make test-watcher` and `make plugin-validate`.

## Releasing

1. Bump `version` in `mix.exs`. Add `## X.Y.Z — date` to `CHANGELOG.md`. If `plugin/` changed, set the same number in `plugin/.claude-plugin/plugin.json`.
2. Run `make precommit` and `make docker-smoke`. Both must pass.
3. Commit, then tag `vX.Y.Z`.
4. Run `make dist`. It produces `c3-X.Y.Z.tar.gz`, the release asset.

How the release is published (who creates the GitHub release, and whether CI does it) is _(undetermined)_ from this repository. CI (`.github/workflows/ci.yml`) only runs `make precommit` plus the tree check, and `make docker-smoke DOCKER=docker`.

Deploying: run the image behind the reverse proxy, published on `<HOST_PORT>`, with `SECRET_KEY_BASE` and `PHX_HOST` set (for example `c3.example.com`) and a persistent volume for the SQLite file.

## Where to go next

| You want | Open |
|---|---|
| Dockerfile stages, compose, overlays, CI jobs in detail | [`../architecture/07-build-release-and-deploy.md`](../architecture/07-build-release-and-deploy.md) |
| Test helpers, fixtures, why DB tests are not async | [`../architecture/06-testing.md`](../architecture/06-testing.md) |
| Every `C3_*` setting and what the container needs | [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md) |
| Writing a migration that `bin/migrate` will run | [`../architecture/02-data-model-and-persistence.md`](../architecture/02-data-model-and-persistence.md) |
| The watcher and plugin scripts that `make test-watcher` covers | [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md) |
| What `/healthz` reports | [`../features/health-and-home/00-INDEX.md`](../features/health-and-home/00-INDEX.md) |
