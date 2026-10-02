# CLAUDE.md — C3

C3 (Central Context Coordinator) is a Phoenix service for stateful messaging between AI agents:
sessions joined with a code + security number, threads whose status is derived from open requests,
a watcher-friendly long-poll event feed, and a remote MCP endpoint.

- Context map: start at [`docs/00-INDEX.md`](docs/00-INDEX.md) before planning a change (refresh with sk-context).
- Phoenix/LiveView conventions for this codebase: see [`AGENTS.md`](AGENTS.md).
- Every command goes through the `Makefile` (`make` lists them). Run `make precommit` before
  finishing a change; `make docker-smoke` when touching the Dockerfile, release or runtime config.
- Database: SQLite via `ecto_sqlite3`. Keep queries portable to Postgres.
- This repository is public: deployment docs and configs stay generic (`example.com`,
  `<HOST_PORT>`, "the reverse proxy"). No real hostnames, IPs or infrastructure details.
- Versions: a release bumps `version` in `mix.exs` (tag `vX.Y.Z`, `## X.Y.Z — date` in
  `CHANGELOG.md`); any change under `plugin/` also bumps `plugin/.claude-plugin/plugin.json` to
  that same number — the plugin's version is pinned, so `claude plugin update` skips it otherwise.
