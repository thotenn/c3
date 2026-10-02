---
doc: architecture/07-build-release-and-deploy
repo: c3
kind: architecture
anchored_to: fa64fbd
generated: 2026-10-02
---
# Build, release and deploy

C3 ships as one Mix release inside a two-stage Docker image. A single container holds the Phoenix server and its SQLite database, both on a `/data` volume. Every `make` target sits on top of the Mix project. CI runs two of those targets. The release asset is a source tarball, not a binary. The Claude Code plugin is versioned on its own, in `plugin/.claude-plugin/plugin.json`, and has a separate update rule.

## How it works

**Mix project.** `mix.exs` declares app `:c3`, version `0.1.0`, Elixir `~> 1.15`. Its `precommit` alias runs `compile --warnings-as-errors`, `deps.unlock --unused`, `format` and `test`, and is pinned to `MIX_ENV=test` through `cli/0` `preferred_envs`. The `Makefile` reads `VERSION` from the first `version: "…"` line of `mix.exs` with `sed`. `.tool-versions` pins erlang 28.3.1 / elixir 1.19.5. The Dockerfile's `ELIXIR_VERSION`/`OTP_VERSION` args repeat those versions by hand.

**Image.** The builder stage fetches and compiles deps before it copies `lib`, so a code-only change reuses the dep layer. It runs `mix assets.deploy`, copies `config/runtime.exs` late, so runtime-config edits don't recompile, then copies `rel` and runs `mix release`. The final stage is Debian slim, running as `nobody`, with `tini` as PID 1. It sets `DATABASE_PATH=/data/c3.db` and `PORT=4000` and declares `VOLUME /data`. Attachments default to `attachments/` next to the database file (`lib/c3/config.ex:attachments_dir`), so they land on the same volume.

**Start sequence.** `CMD` runs `/app/bin/migrate && exec /app/bin/server`. These are the release overlays under `rel/overlays/bin/`: `migrate` evals `C3.Release.migrate`, and `server` sets `PHX_SERVER=true` and runs `c3 start`. Migrations run on every container start and are idempotent. If a migration fails, the server never starts.

**Migrations.** `lib/c3/release.ex:migrate` runs `Ecto.Migrator.with_repo` with `pool_size: 1` on purpose. On a fresh SQLite file, every pooled connection races to switch the file to WAL, and the losers log `database is locked`. `lib/c3/release.ex:rollback` does not pass `pool_size: 1`.

**Health.** `GET /healthz` (`lib/c3_web/router.ex:HealthController`) is probed by `curl` in three places:
- the Dockerfile `HEALTHCHECK`
- the `healthcheck` in `compose.yaml`
- `scripts/docker-smoke.sh`, which waits 30 s, then dumps the container logs and fails.

**CI.** `.github/workflows/ci.yml` has two jobs:
- `test` runs `make precommit` with versions from `.tool-versions`, then `git diff --exit-code`. Precommit formats and unlocks in place, so an unformatted commit fails here.
- `docker` runs `make docker-smoke DOCKER=docker`.

**Release artefact.** `make dist` refuses to run on a dirty tree. It then runs `git archive` on HEAD to produce `c3-<version>.tar.gz` with prefix `c3-<version>/`. Only committed content ships.

**Plugin.** `.claude-plugin/marketplace.json` lists one plugin with `source: ./plugin`. `plugin/.claude-plugin/plugin.json` carries a fixed `version` and a required `userConfig.server_url`. `plugin/.mcp.json` turns that URL into `${user_config.server_url}/mcp`.

## The pieces

| Path | Export | Role |
|---|---|---|
| `lib/c3/release.ex` | `C3.Release.migrate/0` | Runs all migrations with a single connection; called by the `migrate` overlay |
| `lib/c3/release.ex` | `C3.Release.rollback/2` | Rolls back to a version (run by hand via `bin/c3 eval`) |
| `lib/c3/config.ex` | `attachments_dir/0` | Puts attachments next to the SQLite file unless `C3_ATTACHMENTS_DIR` is set |
| `lib/c3/config.ex` | `attachments_request_max_bytes/0` | The largest request body the app accepts on attachment routes; the reverse proxy must allow at least this |
| `lib/c3_web/router.ex` | `/healthz` | The probe target of every health check |
| `plugin/.claude-plugin/plugin.json` | `version` | The plugin version clients compare against |
| `plugin/.mcp.json` | `mcpServers.c3` | Remote MCP endpoint, built from the user-supplied server URL |

These paths are in scope but outside the citable roots: `mix.exs`, `Makefile`, `Dockerfile`, `.dockerignore`, `compose.yaml`, `rel/overlays/bin/{migrate,server}` (plus `.bat` twins), `scripts/docker-smoke.sh`, `.github/workflows/ci.yml`, `.tool-versions`, `.claude-plugin/marketplace.json`.

## How a feature uses it

A feature that adds a migration does nothing extra: the next container start applies it before the server boots. A feature that adds a runtime setting goes through configuration (see `architecture/05-configuration-and-environments`) and reaches the container via `.env` (`env_file` in compose). A feature that changes anything under `plugin/` must bump the plugin version:

```json
{
  "name": "c3",
  "version": "0.1.0",
  "userConfig": { "server_url": { "type": "string", "required": true } }
}
```

## Rules

1. **Bump `version` in `plugin/.claude-plugin/plugin.json` on every plugin change.** Clients compare versions and skip an update whose version didn't change, so the change never reaches them.
2. **Keep `pool_size: 1` in `lib/c3/release.ex:migrate`.** Without it, the first boot on an empty volume logs `database is locked` from the race to switch to WAL.
3. **Change health checks in both the Dockerfile and `compose.yaml`.** Podman ignores the Dockerfile `HEALTHCHECK` when it builds OCI images, so a change to only one of them silently diverges.
4. **Keep the database and attachments on `/data`.** Anything outside the volume is lost on rebuild.
5. **Configure the reverse proxy to accept bodies of at least `lib/c3/config.ex:attachments_request_max_bytes`.** That is about base64(10 MiB) plus the message size plus 64 KiB with the defaults. A proxy at its default limit rejects attachment posts before they reach the app. TLS terminates at the proxy, and the container serves plain HTTP on `4000`, published on `<HOST_PORT>` (`C3_HOST_PORT`).
6. **Commit before `make dist`.** It refuses a dirty tree, and `git archive` would leave out uncommitted work anyway.
7. **Keep the Dockerfile Elixir/OTP args in step with `.tool-versions`.** CI tests against `.tool-versions`, but the image builds with the Dockerfile args.

## Gotchas

- `make dist` packages the source, not the built release. Whoever deploys from the tarball still builds the image.
- `.dockerignore` excludes `/test/`, `*.db*` and `.env*`. A local database or secret never enters the image, and tests can't run inside it.
- Compose overrides `DATABASE_PATH` to the same value the image already sets. Changing only one of the two does nothing visible until they disagree.
- The smoke script makes up its own `SECRET_KEY_BASE` and `PHX_HOST=localhost`, so a passing smoke test says nothing about your `.env`.
- `make docker-down` keeps the `c3_data` volume. Wiping the data takes an explicit volume removal.
- `DOCKER` falls back to `podman`, which is exactly the setup where the Dockerfile health check is ignored (rule 3).

## Who uses it

| Feature | Uses it for |
|---|---|
| Attachments | Storage on the `/data` volume; the reverse proxy body size (`lib/c3/config.ex:attachments_request_max_bytes`) |
| Claude Code plugin | Marketplace entry, version bump rule, `server_url` → `plugin/.mcp.json` |
| Persistence | Migrations on every start via `lib/c3/release.ex:migrate` |
| Health / operations | `/healthz` probes in the image, compose and CI |
