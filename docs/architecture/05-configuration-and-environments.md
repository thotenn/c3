---
doc: architecture/05-configuration-and-environments
repo: c3
kind: architecture
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Configuration and environments

C3 keeps its runtime settings in the `:c3` app env, and each setting has a default. `lib/c3/config.ex:@defaults` holds every default. `config/runtime.exs:c3_env` maps each `C3_*` environment variable to a key and a parser, and writes the key only when its variable is set and not empty. `lib/c3/config.ex:validate!` runs at boot and fails on a bad value right away, instead of letting it break the first request. The per-environment files (`config/dev.exs`, `config/test.exs`, `config/prod.exs`) cover the database, the endpoint and a few test overrides on purpose.

## How it works

Config files load in this order:

1. `config/config.exs`
2. `config/<env>.exs`, loaded by `import_config` at the bottom of `config/config.exs`
3. `config/runtime.exs`, which runs in every environment, releases included

`runtime.exs` loops over `c3_env` with `for {key, {var, parse}} <- c3_env, value <- [System.get_env(var)], value not in [nil, ""]`, so a variable set to an empty string counts as unset. Some parsers change units:
- `*_HOURS` variables are multiplied by 3600.
- `*_MINUTES` variables are multiplied by 60.
- List variables are split on commas by the `csv` lambda.
- `C3_REAL_IP_HEADER` is lower-cased and trimmed.

Every reader calls `lib/c3/config.ex:get`. It does `Application.get_env(:c3, key, Keyword.fetch!(@defaults, key))`, so asking for a key that is not in `@defaults` raises, even if the app env has that key.

`lib/c3/application.ex` calls `C3.Config.validate!()` before it builds the supervision tree. Validation checks the merged result (app env over defaults), so values from `config/test.exs` are checked too.

`runtime.exs` reads a few more variables outside the `C3_*` table:
- In all environments: `PHX_SERVER` and `PORT` (default `"4000"`).
- In prod only: `DATABASE_PATH` (required, or it raises), `SECRET_KEY_BASE` (required), `PHX_HOST` (default `"example.com"`), `POOL_SIZE` (default `"5"`) and `DNS_CLUSTER_QUERY`.

## The pieces

| Path | Export | Role |
|---|---|---|
| `lib/c3/config.ex` | `@defaults` | Holds every default, and is the only place they live. The moduledoc table documents each key. |
| `lib/c3/config.ex` | `get/1` | Reads a setting, falling back to its default. Raises on an unknown key. |
| `lib/c3/config.ex` | `validate!/0` | Checks settings at boot. |
| `lib/c3/config.ex` | `attachments_dir/0` | Returns `:attachments_dir`, or `attachments/` next to `C3.Repo`'s `:database`. |
| `lib/c3/config.ex` | `attachments_request_max_bytes/0` | Body-parser cap for routes that carry attachments: `attachments_message_max_bytes * 4/3 + max_body_bytes + 64 KiB`. |
| `config/runtime.exs` | `c3_env` | Maps each env var to a key and a parser. |
| `config/test.exs` | — | Test overrides (see Gotchas). |
| `config/prod.exs` | `force_ssl` | Forces HTTPS, honoring `rewrite_on: [:x_forwarded_proto]`. Excludes path `/healthz` and hosts `localhost` and `127.0.0.1`. |
| `.env.example` | — | Template for compose deployments. Shows the defaults as commented lines. |

### Settings with an environment variable

| Env var | Key | Default | Validated at boot |
|---|---|---|---|
| `C3_TZ` | `:tz` | `"Etc/UTC"` | Must work with `DateTime.now/1`. The zone database is `Tz.TimeZoneDatabase` (`config/config.exs`). |
| `C3_SECRET_DIGITS` | `:secret_digits` | `6` | Must be in `6..8`. |
| `C3_SESSION_MAX_TTL_HOURS` | `:session_max_ttl` | 7 days, in seconds | Must be > 0. |
| `C3_SESSION_IDLE_TTL_HOURS` | `:session_idle_ttl` | 24 h, in seconds | Must be > 0. |
| `C3_SESSION_CLOSING_SOON_MINUTES` | `:session_closing_soon` | 3600 s | Not checked. |
| `C3_RETENTION_DAYS` | `:retention_days` | `30` | Must be ≥ 0. `0` means purge on close. |
| `C3_LONG_POLL_MAX_WAIT` | `:long_poll_max_wait` | `30` s | Must be > 0. |
| `C3_SSE_KEEPALIVE_SECONDS` | `:sse_keepalive` | `15` | Must be > 0. |
| `C3_JOIN_LOCK_IPS` | `:join_lock_ips` | `3` | Not checked. |
| `C3_UNKNOWN_CODE_LIMIT` | `:unknown_code_limit` | `5` | Not checked. |
| `C3_REAL_IP_HEADER` | `:real_ip_header` | `nil` (use the peer address) | Not checked. |
| `C3_TRUSTED_PROXIES` | `:trusted_proxies` | Loopback and private ranges | Each CIDR must pass `C3.Security.CIDR.parse!`. |
| `C3_IP_ALLOWLIST` | `:ip_allowlist` | `[]` | Each CIDR must pass `C3.Security.CIDR.parse!`. |
| `C3_RATE_LIMIT_TOKEN` | `:rate_limit_token` | `120`/min | Not checked. |
| `C3_RATE_LIMIT_IP` | `:rate_limit_ip` | `300`/min | Not checked. |
| `C3_MAX_BODY_BYTES` | `:max_body_bytes` | `65536` | Not checked. |
| `C3_ATTACHMENT_MAX_BYTES` | `:attachment_max_bytes` | 5 MiB | Must be > 0. |
| `C3_ATTACHMENTS_MESSAGE_MAX_BYTES` | `:attachments_message_max_bytes` | 10 MiB | Must be > 0. |
| `C3_ATTACHMENTS_SESSION_MAX_BYTES` | `:attachments_session_max_bytes` | 50 MiB | Must be > 0. |
| `C3_ATTACHMENTS_DIR` | `:attachments_dir` | `nil` (see `attachments_dir/0`) | Not checked. |
| `C3_CLAIM_TTL_MINUTES` | `:claim_ttl` | 1800 s | Not checked. |
| `C3_MCP_ALLOWED_ORIGINS` | `:mcp_allowed_origins` | `[]` | Not checked. |
| `C3_ADMIN_TOKEN` | `:admin_token` | `nil` (`/admin` returns 404) | If set, must be at least 32 bytes. |
| `C3_METRICS_TOKEN` | `:metrics_token` | `nil` (`/metrics` returns 404) | If set, must be at least 32 bytes. |

### Settings with no environment variable

These keys are not in `config/runtime.exs:c3_env`. They can only be changed in a config file or with `Application.put_env`.

| Key | Default |
|---|---|
| `:admin_session_ttl` | 12 h |
| `:last_seen_throttle` | `60` s |
| `:rate_limit_window_ms` | `60_000` |
| `:attachments_per_message` | `10` |
| `:attachment_inline_max_bytes` | 1 MiB |
| `:sweeper` | `true` |
| `:sweep_interval_ms` | `60_000` (read in `lib/c3/sweeper.ex:schedule`) |

## How a feature uses it

To add a setting:
1. Add the key and its default to `lib/c3/config.ex:@defaults`, and a row to the moduledoc table.
2. If it should be tunable, add an entry to `config/runtime.exs:c3_env` and a commented line to `.env.example`.
3. Add a check to `validate!` if a bad value would only fail later.

Read it like this:

```elixir
C3.Config.get(:claim_ttl)            # seconds, already converted from minutes
C3.Config.get(:sweeper) && C3.Sweeper # lib/c3/application.ex
```

## Rules

1. **Defaults live only in `@defaults`.** A default written in `runtime.exs` would override the app env that `test.exs` sets.
2. **Durations are stored in seconds** (or ms when the key ends in `_ms`), whatever unit the variable uses. Using `*_HOURS` values as hours makes every TTL 3600 times too long.
3. **Leave a variable unset to keep the default.** An empty value is ignored, but a value that does not parse (`String.to_integer("abc")`) crashes `runtime.exs` before `validate!` runs.
4. **Tokens are trimmed, then their bytes are counted.** A token shorter than 32 stops the boot. It does not just disable `/admin` or `/metrics`.
5. **Deployment values stay generic.** `PHX_HOST` defaults to `example.com`. Real hosts go in the deployment's `.env`, which is never committed.

## Gotchas

- **Many limits are not validated.** `validate!` only checks positivity for `session_idle_ttl`, `session_max_ttl`, `long_poll_max_wait`, `sse_keepalive` and the three attachment byte caps. A zero or negative value for `claim_ttl`, `max_body_bytes`, the rate limits, `join_lock_ips`, `unknown_code_limit` or `session_closing_soon` boots without error.
- **`config/test.exs` differs on purpose:**
  - `sweeper: false`: the sweeper would touch the DB outside the SQL sandbox, so tests call its jobs directly.
  - Argon2 runs with `t_cost: 1, m_cost: 8`.
  - `rate_limit_ip: 100_000`.
  - Attachments go under `tmp/`.
  - A fixed `admin_token` is set.
  - `C3.Repo` sets no `default_transaction_mode`, so tests use SQLite's deferred transactions. Dev (`config/dev.exs`) and prod (`config/runtime.exs`) use `:immediate`, which takes the write lock up front. Code that depends on lock behavior can pass in tests and hit busy errors in prod.
- **`force_ssl` is compile-time** and lives in `config/prod.exs`, not `runtime.exs`. `/healthz` is excluded so a health check over plain HTTP is not redirected. Any other probe path you add will get a redirect unless you also add it to `exclude`.
- `C3_REAL_IP_HEADER` is only honored when the peer is in `C3_TRUSTED_PROXIES` (see `.env.example`). Setting the header alone does nothing behind an untrusted peer.
- Raising `C3_ATTACHMENTS_MESSAGE_MAX_BYTES` also raises `attachments_request_max_bytes/0`. The reverse proxy's body limit must grow too, to about 1.4 times the new value.
- `C3_HOST_PORT` in `.env.example` belongs to the compose file. Nothing in `config/` reads it, and the app listens on `PORT`.

## Who uses it

| Feature | Uses it for |
|---|---|
| Boot / supervision (`lib/c3/application.ex`) | `validate!`, and the `:sweeper` toggle |
| Sweeper (`lib/c3/sweeper.ex`) | `:sweep_interval_ms`; the TTL and retention keys _(undetermined in detail)_ |
| Security, rate limiting, admin, metrics, attachments, MCP, event feed | The matching keys listed above; per-module reads _(undetermined)_ |
