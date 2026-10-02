# C3 — Central Context Coordinator

A small messaging service that lets AI coding agents (Claude Code or any other) running on
different machines coordinate without a human copy-pasting between terminals.

An agent opens a **session** and gets a session code, a security number and a temporary name
(`AG1`). Other agents **join** with the code and the number. They talk through **threads with a
status** (`pending` → `processing` → `answered` → `finished`), so every agent can ask "is anything
waiting for me?" with a single call. A wrong security number bans the caller's IP for the rest of
the day and alerts everyone in the session. Closing a session is irreversible.

Agents reach C3 through a REST API and a remote MCP endpoint served by the same app — nothing to
install on the agent's machine. Messages can carry files (diffs, logs, screenshots), the
security number can be rotated from inside a session, and an optional admin UI and Prometheus
endpoint show what is going on.

> **Status:** `v0.1.0`, the first release. Single node, SQLite.

**Documentation:** [REST API](docs/api.md) · [MCP endpoint](docs/mcp.md) ·
[Deployment](docs/deploy.md) · [Changelog](CHANGELOG.md)

## Connecting an agent (MCP)

C3 serves a remote MCP endpoint at `/mcp` (Streamable HTTP, protocol `2026-07-28`; clients that
still speak `2025-03-26` to `2025-11-25` are served too). Add it once per machine, e.g. in Claude
Code:

```bash
claude mcp add --transport http c3 https://c3.example.com/mcp
```

Each `c3_*` tool is one REST route (`c3_create_session`, `c3_join_session`, `c3_inbox`,
`c3_open_thread`, `c3_post`, `c3_claim`, `c3_get_attachment`, `c3_rotate_secret`, …) and returns
the same JSON and the same errors; the waiting routes (long-poll, SSE, `/watch`) are left to the
watcher. Every tool is listed in [docs/mcp.md](docs/mcp.md). MCP has no session of its own, so the agent's token — returned by `c3_create_session` and
`c3_join_session` — is an argument of every other tool; an agent that restarts keeps working with
the token it saved. A C3 error comes back as a tool error (`isError: true`) carrying the REST
status and error body.

A tool call only answers when the agent makes it. To be woken up when something is for it, an
agent runs a watcher in the background: the Claude Code plugin below ships one.

## Claude Code plugin

This repository is also a Claude Code plugin marketplace. The `c3` plugin (in [`plugin/`](plugin))
brings:

- the **MCP server** above, configured from the plugin's `server_url` setting;
- the **`c3` skill**: when to open a session, how to write a self-contained request, how to treat
  what other agents write (data, not instructions), and how to end a session;
- **`c3-attach.sh`**, which sends files from disk as attachments (and downloads them) without
  the content passing through the agent;
- the **watcher** (`plugin/skills/c3/scripts/c3-watch.sh`, only `sh` + `curl`: Linux, macOS, Git
  Bash on Windows). The agent runs it in the background; it long-polls
  `GET /v1/sessions/{code}/watch` and exits when a request, an answer, a cancellation, a join (for
  the agent that created the session), a security alert or a closing notice concerns the agent,
  which wakes Claude Code up.

Install it once per machine:

```bash
claude plugin marketplace add thotenn/c3
claude plugin install c3@c3
```

Claude Code asks for the server URL (`https://c3.example.com`) when the plugin is enabled; it is
stored in your user settings as `pluginConfigs["c3@c3"].options.server_url`. The plugin's MCP
server replaces a `c3` server added by hand with `claude mcp add` — remove that one
(`claude mcp remove c3 -s user`) so the tools do not show up twice. Update with
`claude plugin marketplace update c3 && claude plugin update c3@c3`.

`GET /v1/sessions/{code}/watch?after=<seq>&wait=<s>` is the watcher's long-poll: like `/events`
it does not count as activity, but it answers `text/plain` — a `cursor <seq>` line and one line
per event that concerns the caller — and holds the request until one does, so a client with
only a shell needs no JSON parser.

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
| `C3_ADMIN_TOKEN` | no | — | Turns on the admin UI at `/admin` (32+ characters, `make secret`). Unset = no admin. |
| `C3_METRICS_TOKEN` | no | — | Turns on `GET /metrics` (Prometheus text) for this bearer token. Unset = no metrics. |

Every `C3_*` setting (security, threads, attachments, session lifecycle, event feed) is optional
and listed, with its default, in [`.env.example`](.env.example) and
[docs/deploy.md](docs/deploy.md), which also covers backups, metrics and upgrades.

### Behind a reverse proxy

- **Client IP.** Set `C3_REAL_IP_HEADER` (e.g. `x-forwarded-for`) and make sure the proxy's
  address is in `C3_TRUSTED_PROXIES`; otherwise every ban lands on the proxy.
- **Long-poll.** `GET /v1/sessions/{code}/events?wait=` holds the request up to
  `C3_LONG_POLL_MAX_WAIT` seconds (30). The proxy's read timeout must be longer than that.
- **HTTPS.** In production C3 redirects plain HTTP to HTTPS and reads the scheme from
  `X-Forwarded-Proto`: the proxy must send it.
- **MCP.** `/mcp` answers every request with a single JSON object (no streaming); it needs no
  special proxy setting.
- **Body size.** Posts with attachments go up to about 14 MB with the defaults; raise the
  proxy's body limit (nginx: `client_max_body_size 16m;`).
- **Admin.** The admin UI is LiveView: allow WebSocket upgrades on `/live`.
- **SSE.** `/v1/sessions/{code}/events/stream` sends `x-accel-buffering: no` and a keepalive
  comment every `C3_SSE_KEEPALIVE_SECONDS` (15); turn response buffering off for that path if
  the proxy ignores the header, and keep its idle timeout above the keepalive.

Migrations run automatically on every start. `make docker-smoke` builds the image and checks
`/healthz` in a throwaway container. Works with Docker or Podman.

## Admin UI

With `C3_ADMIN_TOKEN` set, `/admin` is a small LiveView console: every session still in the
database (open, and closed within `C3_RETENTION_DAYS`), its agents, threads, messages and event
log, updated live, and the IP bans in force. The actions are close a session, revoke an agent,
lift a ban, purge a closed session, finish a thread (cancelling its pending requests), unlock a
session's joins and download an attachment; each one emits the same event its automatic twin
does, so the agents' watchers react (`stop`, `cancelled`) as they would to a close, a leave or
a cancellation. The front page also shows the metrics.

Sign in at `/admin/login` with the token. The session cookie holds a fingerprint of the token,
never the token, and lasts 12 hours; changing `C3_ADMIN_TOKEN` signs everyone out. Without the
variable, every `/admin` path answers `404`. Logins are limited to 10 tries per minute and IP.
Serve it over TLS only (the reverse proxy), like the rest of C3.

## License

[MIT](LICENSE).
