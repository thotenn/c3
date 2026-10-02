---
doc: architecture/07-build-release-and-deploy
repo: c3
kind: architecture
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Build, release and deploy

C3 ships as one Mix release in a two-stage Docker image. It runs as a single node, with SQLite on a `/data` volume. The `Makefile` is the only way in: it covers development, tests, the plugin, Docker and the release tarball. `lib/c3/release.ex:C3.Release` runs the database tasks in production, where Mix is not installed. CI runs the same `make` targets a developer runs.

## How it works

**Mix project.** `mix.exs:project` sets `version: "0.1.0"`. The `Makefile` reads `VERSION` by running `sed` over that exact line, and `make dist` names its tarball after it. `mix.exs:cli` sets `preferred_envs: [precommit: :test]`, so `make precommit` always runs in the test env. `mix.exs:aliases` defines `precommit` as `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, then `test`. Two of those steps rewrite files in place. `test` creates and migrates the database first, and `assets.deploy` (minify plus `phx.digest`) is used only by the image build.

**Toolchain pinning.** `.tool-versions` pins `erlang 28.3.1` and `elixir 1.19.5`. The `Dockerfile` repeats those versions as `ARG ELIXIR_VERSION` and `ARG OTP_VERSION`, and CI reads `.tool-versions` through `erlef/setup-beam` with `version-type: strict` (`.github/workflows/ci.yml`). There are two sources of truth, and nothing checks that they agree.

**Image.** The `builder` stage in the `Dockerfile` copies files in cache order: `mix.exs` and `mix.lock`, then the compile-time config, then `deps.compile`, `priv`, `lib`, `assets` and `mix assets.deploy`. Only after that does it copy `config/runtime.exs` and `rel`, then run `mix release`. Changing runtime config or the overlays therefore does not recompile the code.

The `final` stage is a slim Debian image. It installs `curl`, which the healthcheck uses, and `tini`, and it runs as `nobody`. It creates `/data` and declares it as a `VOLUME`. It also sets `DATABASE_PATH="/data/c3.db"` and `PORT="4000"`. Attachments default to `attachments/` next to the database file, which is `/data/attachments` in the image (`lib/c3/config.ex:attachments_dir`). So one volume holds all the state.

**Start sequence.** The image runs `ENTRYPOINT ["/usr/bin/tini", "--"]` and `CMD /app/bin/migrate && exec /app/bin/server`, so migrations run on every container start, before the server starts.
- `rel/overlays/bin/migrate` runs `./c3 eval C3.Release.migrate`.
- `rel/overlays/bin/server` sets `PHX_SERVER=true` and runs `./c3 start`. Without that variable the endpoint does not serve.
- `lib/c3/release.ex:migrate` opens the repo with `pool_size: 1` on purpose. On a fresh SQLite file, every connection in a pool races to switch the file to WAL mode, and the losers log `database is locked`. The server's own pool size comes from `POOL_SIZE` (default 5) in `config/runtime.exs`.
- If migrations fail, the server does not start, because `&&` stops the chain.

**Healthcheck.** Both the `Dockerfile` (`HEALTHCHECK … /healthz`) and `compose.yaml` (`healthcheck:`) declare the same check, with the same timings. Podman drops the Dockerfile `HEALTHCHECK` when it builds OCI-format images, so the compose copy is the one that works there. One difference: the Dockerfile check uses `${PORT}`, but the compose check hardcodes `4000`.

**Compose.** `compose.yaml` is a single-service, single-node stack. It reads `env_file: .env`, which is copied from `.env.example`; prod needs `SECRET_KEY_BASE` and `PHX_HOST` (`config/runtime.exs`). It maps `${C3_HOST_PORT:-4000}:4000` and stores data in the named volume `c3_data`. TLS ends at a reverse proxy in front of it. Attachments make requests larger than normal messages (`C3_MAX_BODY_BYTES`, `C3_ATTACHMENT_MAX_BYTES` in `lib/c3/config.ex`), so the proxy's request-body limit must be raised to fit. The URL host comes from `PHX_HOST`, with port 443 and the https scheme.

**Smoke test.** `make docker-smoke` builds the image, then runs `scripts/docker-smoke.sh`. The script starts a throwaway container with a random `SECRET_KEY_BASE` and `PHX_HOST=localhost`, bound to `127.0.0.1:$(PORT)`. It polls `/healthz` for 30 seconds, and on failure it prints the container logs. A `trap` removes the container on exit.

**CI.** `.github/workflows/ci.yml` has two jobs, on pushes to `main` and on pull requests:
- `test` caches `deps` and `_build`, keyed on `.tool-versions` and `mix.lock`. It runs `make precommit`, then `git diff --exit-code`. Because precommit formats and unlocks in place, a commit that was not formatted fails here.
- `docker` runs `make docker-smoke DOCKER=docker`.

**Release artefact.** `make dist` refuses to run on a dirty tree (`git diff --quiet HEAD`). It then runs `git archive` on **HEAD**, producing `c3-$(VERSION).tar.gz` with the prefix `c3-<version>/`. That means the tarball contains only committed files, and it includes no `.env` or build output. Tagging and publishing are not automated in this repo: _(undetermined)_.

**Plugin marketplace.** `.claude-plugin/marketplace.json` makes the repo root a Claude Code marketplace with a single plugin whose `source` is `./plugin`. That plugin's manifest, `plugin/.claude-plugin/plugin.json`, pins `"version": "0.1.0"`. Clients compare that string to decide whether to update, so a change under `plugin/` without a version bump never reaches them. `make plugin-validate` validates both manifests.

## The pieces

| Path | Export | Role |
|---|---|---|
| `mix.exs` | `C3.MixProject:aliases` | `precommit`, `test` (migrates first), `assets.deploy` for the image |
| `mix.exs` | `C3.MixProject:cli` | Makes `precommit` run under `MIX_ENV=test` |
| `Makefile` | `VERSION`, `DOCKER`, `IMAGE`, `PORT` | `DOCKER` auto-detects docker, falling back to podman; `VERSION` is read from `mix.exs` |
| `Makefile` | `dist` | `git archive` of HEAD; refuses on a dirty tree |
| `Makefile` | `docker-smoke` | Builds the image, then runs `scripts/docker-smoke.sh` |
| `Makefile` | `plugin-validate`, `test-watcher` | Manifest validation; tests for `/watch` and the plugin's shell scripts (these need `sh` and `curl`) |
| `Dockerfile` | `builder`, `final` | Two-stage release image; `/data` volume; tini; runs migrate then server |
| `.dockerignore` | `/priv/static/assets/` | Keeps local built assets, `_build`, `deps` and `test` out of the build context; the image rebuilds the assets itself |
| `compose.yaml` | `services.c3` | Single node: `.env`, `C3_HOST_PORT`, `c3_data` volume, healthcheck repeated for Podman |
| `rel/overlays/bin/migrate` | — | `eval C3.Release.migrate` |
| `rel/overlays/bin/server` | — | `PHX_SERVER=true` then `c3 start` |
| `rel/overlays/bin/migrate.bat`, `rel/overlays/bin/server.bat` | — | Windows equivalents |
| `lib/c3/release.ex` | `C3.Release:migrate` | Runs all migrations up, with `pool_size: 1` |
| `lib/c3/release.ex` | `C3.Release:rollback` | Rolls back to a version; uses the default pool size |
| `scripts/docker-smoke.sh` | — | Throwaway container that must answer `/healthz` within 30s |
| `.github/workflows/ci.yml` | `test`, `docker` | Precommit plus a clean-tree check; image smoke test |
| `.tool-versions` | — | Erlang and Elixir pins that CI uses |
| `.claude-plugin/marketplace.json` | `plugins` | Exposes `./plugin` as the `c3` plugin |

## How a feature uses it

A feature never touches this layer unless it adds runtime configuration or a migration.
- **New env var:** add it to the `c3_env` list in `config/runtime.exs`, give it a default in `lib/c3/config.ex`, and add it to `.env.example`. The image needs no change.
- **New migration:** it runs automatically on the next container start, through `bin/migrate`.
- **Plugin change:** bump the plugin's version.

```json
// plugin/.claude-plugin/plugin.json — bump on ANY change under plugin/
"version": "0.1.0",
```

## Rules

1. **Run `make precommit` before committing.** Otherwise CI fails at `git diff --exit-code`, because precommit reformats the code or unlocks dependencies.
2. **Any change under `plugin/` bumps `plugin/.claude-plugin/plugin.json` `version`**, to the same number as `mix.exs` `version` when cutting a release. Without the bump, `claude plugin update` treats installed clients as current and skips them.
3. **Keep `C3.Release.migrate` at `pool_size: 1`.** Raising it brings back the `database is locked` race on a fresh database file.
4. **Migrations must be idempotent and safe to run before the server on every boot.** A failing migration stops the container from starting, and the restart policy will loop it.
5. **Keep all state under `/data`.** That means the database (`DATABASE_PATH`) and attachments (`C3_ATTACHMENTS_DIR`, or the default next to the database). A path outside the volume is lost on the next rebuild.
6. **Change the healthcheck in both `Dockerfile` and `compose.yaml`.** Editing only one leaves Podman or Docker running an outdated check.
7. **Bump Erlang/Elixir in `.tool-versions` and in the `Dockerfile` ARGs together.** Otherwise CI and the image compile on different toolchains.
8. **Run `make docker-smoke`** after touching the `Dockerfile`, `rel/`, `config/runtime.exs` or `lib/c3/release.ex`. Unit tests do not exercise any of them.
9. **Deployment docs and configs stay generic** (`example.com`, `<HOST_PORT>`, "the reverse proxy"). This repo is public.

## Gotchas

- `make dist` packages **HEAD**, not the working tree. Committed-but-unpushed work is included; uncommitted work makes it fail. It never builds the Docker image.
- `VERSION` comes from a `sed` match on `version: "…",` in `mix.exs`. Reformatting that line, for example to use a module attribute, silently produces `c3-.tar.gz`.
- Running `bin/server` on its own skips migrations; only the image `CMD` chains them. `c3 start` without the overlay does not set `PHX_SERVER`, so nothing listens.
- `C3.Release.rollback` does not pass `pool_size: 1`. Running it against a fresh database file can hit the same lock warnings.
- The compose healthcheck hardcodes port `4000`, so changing the container's `PORT` breaks it. The host side is `C3_HOST_PORT`, not `PORT`.
- `make docker-smoke` binds `127.0.0.1:$(PORT)`, so it fails if a `make dev` server is already using port 4000. Use `make docker-smoke PORT=4001`.
- In the CI cache, `restore-keys` falls back to any older `mix-<os>-` cache. A stale `_build` can mask a problem that only shows up from a clean build. The `docker` job always builds from scratch.
- `.dockerignore` excludes `/test/`, so the image cannot run tests. It keeps `.git/HEAD` and `.git/refs`, but nothing in the build reads them.
- The prod default `PHX_HOST` is `example.com` (`config/runtime.exs`). Forgetting to set it gives wrong generated URLs, with no error.

## Who uses it

| Feature | Uses it for |
|---|---|
| Attachments | Storage under `/data`; the reverse proxy's body limit must allow `C3_ATTACHMENT_MAX_BYTES` |
| Claude Code plugin (`plugin/`) | Marketplace manifest, `plugin-validate`, `test-watcher`, the pinned version bump |
| Health / metrics | `/healthz` used by the Dockerfile and compose healthchecks and by the smoke script |
| Every schema change | `bin/migrate` on every container start |
