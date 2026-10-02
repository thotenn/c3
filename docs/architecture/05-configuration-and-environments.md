---
doc: architecture/05-configuration-and-environments
repo: c3
kind: architecture
anchored_to: e99b2ae
generated: 2026-10-02
---
# Configuration and environments

Every C3 setting has a single default, in `lib/c3/config.ex:@defaults`. Code reads settings at runtime through `lib/c3/config.ex:get/1`. The environment variables in `config/runtime.exs` only replace a default when the variable is set and not empty. This keeps every default in one module, so a deployment that sets nothing still boots into a sane, generic configuration. `lib/c3/config.ex:validate!` runs at boot and rejects settings that would otherwise only fail at the first request.

## How it works

1. **Compile-time files.** `config/config.exs` sets the endpoint, the asset builders, `:filter_parameters` (`"password"`, `"secret"`, `"token"`, so the security number and agent tokens never reach the logs) and the `Tz.TimeZoneDatabase` used by `C3_TZ`. It then imports `config/dev.exs`, `config/test.exs` or `config/prod.exs`.
2. **Runtime file.** `config/runtime.exs` runs in every environment, releases included. It holds a keyword list `c3_env` of `key: {"C3_VAR", parser}`. The `for` comprehension skips variables that are `nil` or `""` and writes the others into the `:c3` app env. Because of the skip, an empty `C3_ADMIN_TOKEN=` in `.env` leaves the setting unset. It is not an empty token.
3. **Unit conversion happens in the parser, not in the code.** The `*_HOURS` and `*_MINUTES` variables are multiplied into seconds in `config/runtime.exs`. Code that reads the setting always gets seconds.
4. **Reading.** `lib/c3/config.ex:get/1` calls `Application.get_env(:c3, key, Keyword.fetch!(@defaults, key))`. A key that is missing from `@defaults` raises, even if the app env sets it.
5. **Validation.** `lib/c3/application.ex` calls `C3.Config.validate!()` before the supervision tree starts. A raised `ArgumentError` stops the boot.

### Every setting

| Key | Env var | Default | Parsed by `runtime.exs` | `validate!` |
|---|---|---|---|---|
| `:tz` | `C3_TZ` | `"Etc/UTC"` | as-is | must be accepted by `DateTime.now/1` |
| `:secret_digits` | `C3_SECRET_DIGITS` | `6` | integer | `6..8` |
| `:session_max_ttl` | `C3_SESSION_MAX_TTL_HOURS` | 7 days (s) | hours ×3600 | `> 0` |
| `:session_idle_ttl` | `C3_SESSION_IDLE_TTL_HOURS` | 24 h (s) | hours ×3600 | `> 0` |
| `:session_closing_soon` | `C3_SESSION_CLOSING_SOON_MINUTES` | 3600 s | minutes ×60 | not checked |
| `:retention_days` | `C3_RETENTION_DAYS` | `30` | integer | `>= 0` (`0` = purge on close) |
| `:long_poll_max_wait` | `C3_LONG_POLL_MAX_WAIT` | `30` s | integer (seconds) | `> 0` |
| `:sse_keepalive` | `C3_SSE_KEEPALIVE_SECONDS` | `15` | integer | `> 0` |
| `:join_lock_ips` | `C3_JOIN_LOCK_IPS` | `3` | integer | not checked |
| `:unknown_code_limit` | `C3_UNKNOWN_CODE_LIMIT` | `5` | integer | not checked |
| `:secret_tolerance` | `C3_SECRET_TOLERANCE` | `2` | integer | integer `>= 0` |
| `:ipv6_prefix` | `C3_IPV6_PREFIX` | `64` | integer | integer in `32..128` |
| `:real_ip_header` | `C3_REAL_IP_HEADER` | `nil` (TCP peer) | trimmed and downcased | not checked |
| `:trusted_proxies` | `C3_TRUSTED_PROXIES` | loopback + private ranges (IPv4 and IPv6) | CSV | each entry must parse with `C3.Security.CIDR.parse!` |
| `:ip_allowlist` | `C3_IP_ALLOWLIST` | `[]` | CSV | each entry must parse as a CIDR |
| `:rate_limit_token` | `C3_RATE_LIMIT_TOKEN` | `120`/min | integer | not checked |
| `:rate_limit_ip` | `C3_RATE_LIMIT_IP` | `300`/min | integer | not checked |
| `:max_body_bytes` | `C3_MAX_BODY_BYTES` | `65536` | integer | not checked |
| `:attachment_max_bytes` | `C3_ATTACHMENT_MAX_BYTES` | 5 MiB | integer | `> 0` |
| `:attachments_message_max_bytes` | `C3_ATTACHMENTS_MESSAGE_MAX_BYTES` | 10 MiB | integer | `> 0` |
| `:attachments_session_max_bytes` | `C3_ATTACHMENTS_SESSION_MAX_BYTES` | 50 MiB | integer | `> 0` |
| `:attachments_dir` | `C3_ATTACHMENTS_DIR` | `nil` (`attachments/` next to the DB) | trimmed | not checked |
| `:claim_ttl` | `C3_CLAIM_TTL_MINUTES` | 30 min (s) | minutes ×60 | not checked |
| `:mcp_allowed_origins` | `C3_MCP_ALLOWED_ORIGINS` | `[]` | CSV | not checked |
| `:admin_token` | `C3_ADMIN_TOKEN` | `nil` (`/admin` → 404) | trimmed | `nil`, or 32 bytes or more |
| `:metrics_token` | `C3_METRICS_TOKEN` | `nil` (`/metrics` → 404) | trimmed | `nil`, or 32 bytes or more |

### Settings with no environment variable

These can only be changed in a `config/*.exs` file or with `Application.put_env` (in tests):

| Key | Default |
|---|---|
| `:last_seen_throttle` | `60` s between two `last_seen_at` writes of an agent, and between two `last_activity_at` writes of a session |
| `:admin_session_ttl` | 12 h |
| `:attachments_per_message` | `10` |
| `:attachment_inline_max_bytes` | 1 MiB |
| `:rate_limit_window_ms` | `60_000` |
| `:sweeper` | `true` |
| `:sweep_interval_ms` | `60_000` |

### Non-`C3_*` variables

`config/runtime.exs` also reads the following:

- **Every environment:** `PHX_SERVER` (turns on `server: true`) and `PORT` (default `4000`).
- **Prod only:**
  - `DATABASE_PATH` (required; boot raises without it)
  - `POOL_SIZE` (default `5`)
  - `SECRET_KEY_BASE` (required)
  - `PHX_HOST` (default placeholder `example.com`)
  - `DNS_CLUSTER_QUERY`

`.env.example` also has `C3_HOST_PORT`. The app never reads it: only the compose file uses it, for the published `<HOST_PORT>`.

### Per environment

| | dev (`config/dev.exs`) | test (`config/test.exs`) | prod (`config/prod.exs` + `runtime.exs`) |
|---|---|---|---|
| DB | `c3_dev.db`, `default_transaction_mode: :immediate` | `c3_test.db`, `Ecto.Adapters.SQL.Sandbox`, **no** `:immediate` (deferred transactions) | `DATABASE_PATH`, `:immediate` |
| Bind | loopback | loopback, `server: false` | all interfaces (IPv6 any), URL scheme https on port 443 |
| Sweeper | on | `sweeper: false`, because it would touch the DB outside the sandbox; tests call its jobs directly | on |
| Argon2 | library default | `t_cost: 1, m_cost: 8` (cheap) | library default |
| Rate limit per IP | 300 | `rate_limit_ip: 100_000` | 300 / env |
| Admin token | unset | a fixed 32+ character token, so `/admin` is on | env |
| Attachments dir | next to the DB | `tmp/attachments_test` | env or next to the DB |
| SSL | none | none | `force_ssl` with `rewrite_on: [:x_forwarded_proto]`, excluding path `/healthz` and hosts `localhost`/`127.0.0.1` |

## The pieces

| Path | Export | Role |
|---|---|---|
| `lib/c3/config.ex` | `@defaults` | The only place defaults live |
| `lib/c3/config.ex` | `get/1` | Reads a setting, falling back to its default |
| `lib/c3/config.ex` | `validate!/0` | Fails the boot on a bad setting |
| `lib/c3/config.ex` | `attachments_dir/0` | Resolves `nil` to `attachments/` beside `C3.Repo`'s `:database` |
| `lib/c3/config.ex` | `attachments_request_max_bytes/0` | Body-parser cap on attachment routes: `attachments_message_max_bytes`×4/3 + `max_body_bytes` + 64 KiB |
| `config/runtime.exs` | `c3_env` | Env var → key + parser table |
| `config/test.exs` | `sweeper`, `rate_limit_ip`, `admin_token` | Test-only overrides |
| `config/prod.exs` | `force_ssl` | HTTPS redirect and HSTS, with `/healthz` excluded |
| `.env.example` | — | The operator-facing list, defaults shown commented out |
| `lib/c3/application.ex` | `start/2` | Calls `validate!` and starts `C3.Sweeper` only when `:sweeper` is true |

## How a feature uses it

To add a setting:

1. Add the key and its default to `@defaults`.
2. If operators should be able to set it, add a row to `c3_env`.
3. Add a row to the `@moduledoc` table.
4. If it is an env var, add a commented line to `.env.example`.
5. If a bad value would break later, add a check to `validate!`.

```elixir
# lib/c3/config.ex @defaults
claim_ttl: 30 * 60,
# config/runtime.exs c3_env
claim_ttl: {"C3_CLAIM_TTL_MINUTES", &(String.to_integer(&1) * 60)},
# caller
C3.Config.get(:claim_ttl)
```

If you skip `@defaults`, `get/1` raises `KeyError`, even in environments where the key is configured.

## Rules

1. **Defaults only in `@defaults`.** Defining a default in `runtime.exs` or at the call site creates two sources that drift apart.
2. **Never call `Application.get_env(:c3, …)` directly for these keys.** It bypasses the default, so `nil` reaches code that expects a value.
3. **Store durations in seconds or milliseconds, and convert in the parser.** Callers assume the stored unit. A minutes value read as seconds shortens a TTL 60 times.
4. **Use placeholders in committed config and `.env.example`.** The repository is public.
5. **`force_ssl` is compile-time** and set in `config/prod.exs`. Changing it in `runtime.exs` has no effect.

## Gotchas

- **Not every numeric setting is validated.** `validate!` rejects zero or negative values only for `session_idle_ttl`, `session_max_ttl`, `long_poll_max_wait`, `sse_keepalive` and the three attachment byte limits. `retention_days` and `secret_tolerance` must be `>= 0`. These are not checked at all: `session_closing_soon`, `claim_ttl`, `join_lock_ips`, `unknown_code_limit`, the rate limits and `max_body_bytes`.
- **A non-numeric value crashes the boot, not `validate!`.** `String.to_integer/1` raises while `runtime.exs` is evaluated.
- **Token length is checked in bytes** (`byte_size >= 32`), after trimming.
- **An empty env var is the same as an unset one.** `C3_IP_ALLOWLIST=` keeps the default instead of clearing it. To shrink `trusted_proxies` you must list the ranges explicitly.
- **`C3_REAL_IP_HEADER` only takes effect when the TCP peer is in `trusted_proxies`.**
- **The test DB does not use `default_transaction_mode: :immediate`,** unlike dev and prod. A bug that depends on taking the write lock up front can pass in tests and fail in prod.
- **Tests run with `admin_token` set.** A test that needs `/admin` to return 404 has to unset it itself (`C3.AdminTest` does).
- **Raising `C3_ATTACHMENTS_MESSAGE_MAX_BYTES` also raises the accepted request size** (`attachments_request_max_bytes/0`). The reverse proxy's body limit has to follow, at about 1.4×.
- **`C3_LONG_POLL_MAX_WAIT` must stay below the reverse proxy's read timeout.**
- **`/healthz` is excluded from `force_ssl`,** so an HTTP health check is not redirected.

## Who uses it

| Feature | Uses it for |
|---|---|
| Sessions lifecycle / sweeper | `session_*_ttl`, `session_closing_soon`, `retention_days`, `sweeper`, `sweep_interval_ms` |
| Join security / bans | `tz`, `secret_digits`, `join_lock_ips`, `unknown_code_limit`, `secret_tolerance`, `ipv6_prefix`, `ip_allowlist`, `real_ip_header`, `trusted_proxies` |
| Rate limiting | `rate_limit_token`, `rate_limit_ip`, `rate_limit_window_ms` |
| Threads / claims | `max_body_bytes`, `claim_ttl`, `last_seen_throttle` |
| Attachments | `attachment_*`, `attachments_*` |
| Event feed | `long_poll_max_wait`, `sse_keepalive` |
| MCP endpoint | `mcp_allowed_origins` |
| Admin / metrics | `admin_token`, `admin_session_ttl`, `metrics_token` |
