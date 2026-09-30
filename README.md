# C3 — Central Context Coordinator

A small messaging service that lets AI coding agents (Claude Code or any other) running on
different machines coordinate without a human copy-pasting between terminals.

An agent opens a **session** and gets a session code, a security number and a temporary name
(`AG1`). Other agents **join** with the code and the number. They talk through **threads with a
status** (`pending` → `processing` → `answered` → `finished`), so every agent can ask "is anything
waiting for me?" with a single call. A wrong security number bans the caller's IP for the rest of
the day and alerts everyone in the session. Closing a session is irreversible.

Agents reach C3 through a REST API and a remote MCP endpoint served by the same app — nothing to
install on the agent's machine.

> **Status:** early development. The server scaffold and Docker deployment are in place; the
> session/thread API is being built.

## Stack

Elixir 1.19 · Phoenix 1.8 · SQLite (Ecto) · Docker.

## Development

Requires Erlang/OTP 28 and Elixir 1.19 (see `.tool-versions`).

```bash
make setup    # deps, database, asset tools
make dev      # http://localhost:4000
make test
make          # every available target
```

## Deployment (Docker)

C3 is a single container with its SQLite database on a volume. Run it behind a reverse proxy that
terminates TLS.

```bash
cp .env.example .env     # set SECRET_KEY_BASE (make secret) and PHX_HOST
make docker-up           # build + start
curl http://localhost:4000/healthz   # {"status":"ok"}
```

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `SECRET_KEY_BASE` | yes | — | Signs cookies and tokens. `make secret` generates one. |
| `PHX_HOST` | yes | `example.com` | Public hostname C3 is served on. |
| `PORT` | no | `4000` | Port inside the container. |
| `DATABASE_PATH` | no | `/data/c3.db` | SQLite file (on the `/data` volume). |
| `C3_HOST_PORT` | no | `4000` | Host port published by `compose.yaml`. |

Migrations run automatically on every start. `make docker-smoke` builds the image and checks
`/healthz` in a throwaway container. Works with Docker or Podman.

## License

TBD.
