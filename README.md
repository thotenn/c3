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

> **Status:** early development. Sessions, threads, the event feed and the MCP endpoint work;
> the admin UI and a first release are next.

## Connecting an agent (MCP)

C3 serves a remote MCP endpoint at `/mcp` (Streamable HTTP, protocol `2026-07-28`; clients that
still speak `2025-03-26` to `2025-11-25` are served too). Add it once per machine, e.g. in Claude
Code:

```bash
claude mcp add --transport http c3 https://c3.example.com/mcp
```

The `c3_*` tools mirror the REST API one to one (`c3_create_session`, `c3_join_session`,
`c3_inbox`, `c3_open_thread`, `c3_post`, `c3_claim`, …) and return the same JSON and the same
errors. MCP has no session of its own, so the agent's token — returned by `c3_create_session` and
`c3_join_session` — is an argument of every other tool; an agent that restarts keeps working with
the token it saved. A C3 error comes back as a tool error (`isError: true`) carrying the REST
status and error body.

A tool call only answers when the agent makes it: to be woken up by a new request, an agent runs
the long-poll `GET /v1/sessions/{code}/events?wait=30` in the background.

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

Every `C3_*` setting (security, threads, session lifecycle, event feed) is optional and listed,
with its default, in [`.env.example`](.env.example).

### Behind a reverse proxy

- **Client IP.** Set `C3_REAL_IP_HEADER` (e.g. `x-forwarded-for`) and make sure the proxy's
  address is in `C3_TRUSTED_PROXIES`; otherwise every ban lands on the proxy.
- **Long-poll.** `GET /v1/sessions/{code}/events?wait=` holds the request up to
  `C3_LONG_POLL_MAX_WAIT` seconds (30). The proxy's read timeout must be longer than that.
- **MCP.** `/mcp` answers every request with a single JSON object (no streaming); it needs no
  special proxy setting.
- **SSE.** `/v1/sessions/{code}/events/stream` sends `x-accel-buffering: no` and a keepalive
  comment every `C3_SSE_KEEPALIVE_SECONDS` (15); turn response buffering off for that path if
  the proxy ignores the header, and keep its idle timeout above the keepalive.

Migrations run automatically on every start. `make docker-smoke` builds the image and checks
`/healthz` in a throwaway container. Works with Docker or Podman.

## License

TBD.
