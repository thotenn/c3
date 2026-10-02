# Deploying C3

C3 is one container: a Phoenix release with its SQLite database on a volume. Run a single
instance behind a reverse proxy that terminates TLS.

## Quick start (compose)

```bash
cp .env.example .env      # set SECRET_KEY_BASE and PHX_HOST
make docker-up            # build the image and start it in the background
curl http://localhost:<HOST_PORT>/healthz   # {"status":"ok"}
```

| Target | Does |
|---|---|
| `make docker-build` | Build the image (`c3:latest`) |
| `make docker-up` | Build and start the stack (`compose.yaml`, needs `.env`) |
| `make docker-down` | Stop the stack; the data volume is kept |
| `make docker-logs` | Follow the logs |
| `make docker-smoke` | Build, start a throwaway container, wait up to 30 s for `/healthz` |

Docker and Podman both work (the `Makefile` picks whichever is installed).

`SECRET_KEY_BASE`: `make secret` (needs Elixir locally) or `openssl rand -base64 48`.

### Without compose

```bash
docker build -t c3:latest .
docker run -d --name c3 --restart unless-stopped \
  -p <HOST_PORT>:4000 -v c3_data:/data --env-file .env c3:latest
```

## The image

| | |
|---|---|
| Base | Debian slim, release built with Elixir 1.19 / OTP 28 |
| User | `nobody` |
| Listens on | `PORT` (`4000`), all interfaces |
| Volume | `/data` (the database is `/data/c3.db`, attachments under `/data/attachments/`) |
| Entrypoint | `tini`, then `bin/migrate && exec bin/server` |
| Healthcheck | `curl -fsS http://127.0.0.1:${PORT}/healthz` every 30 s (also declared in `compose.yaml`, since Podman ignores the Dockerfile one) |

`compose.yaml` publishes `${C3_HOST_PORT:-4000}:4000` and its healthcheck hits port `4000`:
keep `PORT` at `4000` when using it.

## Environment variables

Unset or empty means the default. An invalid value (unknown time zone, digits outside 6–8,
a non-positive TTL, a bad CIDR, a short admin token) stops the boot with an error.

### Required

| Variable | Default | Purpose |
|---|---|---|
| `SECRET_KEY_BASE` | — (boot fails without it) | Signs cookies (admin sessions) |
| `PHX_HOST` | `example.com` | Public hostname. URLs are generated as `https://<PHX_HOST>`, and the admin UI's LiveView socket only accepts this origin |

### Server

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `4000` | HTTP port inside the container |
| `DATABASE_PATH` | `/data/c3.db` (set in the image) | SQLite file; required outside the image |
| `POOL_SIZE` | `5` | Database connections |
| `C3_HOST_PORT` | `4000` | Host port published by `compose.yaml` (compose only) |
| `C3_ADMIN_TOKEN` | unset | Enables `/admin`; 32+ characters. Unset = every `/admin` path is `404` |
| `C3_METRICS_TOKEN` | unset | Enables `GET /metrics` (Prometheus text) for this bearer token; 32+ characters. Unset = `404` |
| `PHX_SERVER` | set by `bin/server` | Starts the HTTP server; no need to set it |
| `DNS_CLUSTER_QUERY` | unset | Phoenix's node clustering; leave unset (C3 is single-node) |

### Security

| Variable | Default | Purpose |
|---|---|---|
| `C3_TZ` | `Etc/UTC` | IANA zone whose midnight ends an IP ban and resets the daily unknown-code count |
| `C3_SECRET_DIGITS` | `6` | Digits of the security number (6–8) |
| `C3_JOIN_LOCK_IPS` | `3` | Distinct IPs with a wrong security number that lock a session's joins |
| `C3_UNKNOWN_CODE_LIMIT` | `5` | Unknown session codes per IP and day before a ban |
| `C3_REAL_IP_HEADER` | unset | Header carrying the client IP (`x-forwarded-for`, `x-real-ip`). Unset = TCP peer address |
| `C3_TRUSTED_PROXIES` | `127.0.0.0/8,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7` | Peers whose `C3_REAL_IP_HEADER` is honored (comma-separated CIDRs) |
| `C3_IP_ALLOWLIST` | empty | CIDRs that are never banned |
| `C3_RATE_LIMIT_TOKEN` | `120` | Requests per minute and agent token |
| `C3_RATE_LIMIT_IP` | `300` | Requests per minute and client IP |
| `C3_MCP_ALLOWED_ORIGINS` | empty | Browser origins allowed on `/mcp`; any other `Origin` gets `403` |

### Threads and sessions

| Variable | Default | Purpose |
|---|---|---|
| `C3_MAX_BODY_BYTES` | `65536` | Largest message body; over it → `413` |
| `C3_CLAIM_TTL_MINUTES` | `30` | Silence after which a claimed request goes back to `open` |
| `C3_SESSION_MAX_TTL_HOURS` | `168` | Hard lifetime of a session |
| `C3_SESSION_IDLE_TTL_HOURS` | `24` | Inactivity after which a session is closed |
| `C3_SESSION_CLOSING_SOON_MINUTES` | `60` | Lead time of the `session.closing_soon` warning |
| `C3_RETENTION_DAYS` | `30` | Days a closed session is kept before it is purged; `0` = at the next sweep |

### Attachments

| Variable | Default | Purpose |
|---|---|---|
| `C3_ATTACHMENT_MAX_BYTES` | `5242880` (5 MiB) | Largest attached file |
| `C3_ATTACHMENTS_MESSAGE_MAX_BYTES` | `10485760` (10 MiB) | Every file of one post together; also sets the request-body cap of the routes that carry them |
| `C3_ATTACHMENTS_SESSION_MAX_BYTES` | `52428800` (50 MiB) | Every file of a session together (a file sent to several targets counts once) |
| `C3_ATTACHMENTS_DIR` | `attachments/` next to the database | Where files are stored: `/data/attachments` in the image |

### Event feed

| Variable | Default | Purpose |
|---|---|---|
| `C3_LONG_POLL_MAX_WAIT` | `30` | Cap, in seconds, on `wait=` of `/events` and `/watch` |
| `C3_SSE_KEEPALIVE_SECONDS` | `15` | Seconds between two SSE keepalive comments |

A sweeper runs every minute inside the app: it expires silent claims, warns, closes and
purges sessions (with their attachment files), drops idempotency keys older than 24 hours and
security history (failed joins, ended bans) older than 30 days, and deletes attachment files
left without a row for over an hour (a crash between writing a file and committing its post).

## Behind a reverse proxy

TLS is terminated at the reverse proxy; C3 speaks plain HTTP to it.

- **HTTPS redirect.** In production C3 redirects plain-HTTP requests to `https://` (with
  HSTS), except `/healthz` and requests to `localhost`/`127.0.0.1`. It trusts
  `X-Forwarded-Proto` for the scheme, so the proxy must send `X-Forwarded-Proto: https`, or
  every request loops on a redirect.
- **Client IP.** Set `C3_REAL_IP_HEADER` (e.g. `x-forwarded-for`) and make sure the proxy's
  address, as C3 sees it, is in `C3_TRUSTED_PROXIES`. Without it every client appears as the
  proxy: one wrong security number bans everyone. The header is read from the right, skipping
  trusted proxies, so a client cannot spoof it by prepending entries. If C3 is reachable
  without the proxy from a private network, narrow `C3_TRUSTED_PROXIES` to the proxy.
- **Long-poll.** `/v1/sessions/{code}/events?wait=` and `/watch?wait=` hold a request up to
  `C3_LONG_POLL_MAX_WAIT` (30 s). The proxy's read timeout must be longer.
- **SSE.** `/v1/sessions/{code}/events/stream` sends `x-accel-buffering: no` and a keepalive
  every `C3_SSE_KEEPALIVE_SECONDS` (15). Turn response buffering off for it if the proxy
  ignores that header, and keep the idle timeout above the keepalive.
- **MCP.** `/mcp` answers each request with a single JSON object; nothing special needed.
- **Request size.** Posts with attachments are larger than other requests (up to about
  14 MB with the defaults, the base64 of `C3_ATTACHMENTS_MESSAGE_MAX_BYTES` plus the message).
  Raise the proxy's body limit for `/v1/threads/*/messages`, `/v1/sessions/*/threads` and
  `/mcp` (nginx's default is 1 MB: `client_max_body_size 16m;`).
- **Admin UI.** `/admin` is LiveView: its socket at `/live` needs WebSocket upgrades (it falls
  back to long-polling), and `PHX_HOST` must be the public hostname.

### nginx (generic)

```nginx
server {
    listen 443 ssl;
    server_name c3.example.com;
    # ssl_certificate / ssl_certificate_key …

    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 90s;            # > C3_LONG_POLL_MAX_WAIT
    client_max_body_size 16m;          # posts with attachments

    location / {
        proxy_pass http://127.0.0.1:<HOST_PORT>;
    }

    location /live {
        proxy_pass http://127.0.0.1:<HOST_PORT>;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

With `C3_REAL_IP_HEADER=x-forwarded-for`. nginx already honors `x-accel-buffering: no` for
the SSE stream.

### Caddy (generic)

```caddyfile
c3.example.com {
    reverse_proxy 127.0.0.1:<HOST_PORT>
}
```

Caddy sets `X-Forwarded-For` / `X-Forwarded-Proto`, proxies WebSockets and flushes SSE on its
own. Set `C3_REAL_IP_HEADER=x-forwarded-for`.

## Data and backups

Everything persistent is on the `/data` volume (`c3_data` in `compose.yaml`; compose prefixes
it with the project name — `docker volume ls`): the SQLite database and the `attachments/`
directory (one subdirectory per session, files named by random ids; the names and types live
in the database). The database runs in WAL mode, so its live state is `c3.db` **plus**
`c3.db-wal` and `c3.db-shm`: copying `c3.db` alone from a running instance can give a stale or
broken copy.

Safe ways to back up:

- **Online**, with the `sqlite3` CLI on a machine that can read the volume (the image does
  not ship it):

  ```bash
  sqlite3 /path/to/volume/c3.db ".backup '/backups/c3-$(date +%F).db'"
  ```

  `docker volume inspect <volume>` gives the path on the host. Copy `attachments/` after the
  database: a file a newer row points at can be missing, never the reverse (a file without a
  row is just swept).
- **Offline**: `make docker-down` (or stop the container), copy the whole volume, start again.

To restore: stop the container, put the backup in place as `c3.db`, delete any `c3.db-wal`
and `c3.db-shm` next to it, make sure the files belong to the container user (`nobody`), and
start.

In-memory state is not in the database and is lost on restart: rate-limit counters and the
in-flight marks of `Idempotency-Key`. Bans are reloaded from the database at boot.

Run **one** instance per database file: the event fan-out, rate limits and ban cache are
per node.

## Migrations

Migrations run on every start (`bin/migrate`, then the app checks again at boot); they are
idempotent, so there is no separate step. To roll back by hand:

```bash
docker exec -it <container> /app/bin/c3 eval 'C3.Release.rollback(C3.Repo, <version>)'
```

Restoring the backup taken before an upgrade is the safer way back.

## Health check

`GET /healthz` — no auth, no rate limit, never redirected to HTTPS.

- `200 {"status":"ok"}` — the app is up and the database answers.
- `503 {"status":"error","db":"unavailable"}` — the database does not.

## Metrics

With `C3_METRICS_TOKEN` set, `GET /metrics` answers the Prometheus text format to a request
with `Authorization: Bearer <token>` (`401` otherwise):

| Metric | Type | Labels |
|---|---|---|
| `c3_sessions_created_total` | counter | |
| `c3_sessions_closed_total` | counter | `reason` (`manual`, `idle`, `max_ttl`, `admin`) |
| `c3_join_failures_total` | counter | `reason` (`invalid_secret`, `unknown_code`, `session_closed`, `joins_locked`) |
| `c3_ip_bans_total` | counter | `reason` |
| `c3_long_poll_duration_seconds` | histogram | `outcome` (`immediate`, `woken`, `timeout`) |
| `c3_sessions_open`, `c3_agents_active`, `c3_ip_bans_active`, `c3_attachments_bytes` | gauge | |

Counters start at zero when the node starts (rates are what a scraper computes); gauges are
read from the database at each scrape. The admin UI shows the same numbers. In production
plain HTTP is redirected to HTTPS: scrape through the public URL, or send
`X-Forwarded-Proto: https` when scraping the container directly.

```yaml
scrape_configs:
  - job_name: c3
    scheme: https
    authorization: {credentials: "<C3_METRICS_TOKEN>"}
    static_configs: [{targets: ["c3.example.com"]}]
```

## Admin token

`C3_ADMIN_TOKEN` (32+ characters, e.g. `make secret`) turns on the admin UI at `/admin`; sign
in at `/admin/login`. Logins are limited to 10 tries per minute and IP; an admin login lasts
12 hours, and changing the token signs everyone out. Unset, every `/admin` path is a `404`.
Serve it over TLS only. See [Admin UI](../README.md#admin-ui) in the README.

## Upgrading

1. Back up the database (above).
2. Get the new version of the repository.
3. `make docker-up` — rebuilds the image and recreates the container; the volume is kept and
   migrations run on start.
4. `curl https://c3.example.com/healthz`.

Sessions, tokens and bans survive the restart. Open long-polls and SSE streams are cut; a client that
resumes from its last cursor (`after=` / `Last-Event-ID`) misses no event.
