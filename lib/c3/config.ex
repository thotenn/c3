defmodule C3.Config do
  @moduledoc """
  Runtime settings, read from the `:c3` app env with generic defaults. `config/runtime.exs`
  only sets the keys whose environment variable is present, so every default lives here.

  | Key | Env var | Default |
  |---|---|---|
  | `:tz` | `C3_TZ` | `"Etc/UTC"` — IANA zone whose midnight ends an IP ban |
  | `:secret_digits` | `C3_SECRET_DIGITS` | `6` (6..8) |
  | `:session_max_ttl` | `C3_SESSION_MAX_TTL_HOURS` | 7 days, in seconds |
  | `:session_idle_ttl` | `C3_SESSION_IDLE_TTL_HOURS` | 24 h, in seconds — a session without activity that long is closed |
  | `:session_closing_soon` | `C3_SESSION_CLOSING_SOON_MINUTES` | 60 min, in seconds — how long before either close `session.closing_soon` goes out |
  | `:retention_days` | `C3_RETENTION_DAYS` | `30` — days a closed session is kept before the purge; `0` = purge on close |
  | `:long_poll_max_wait` | `C3_LONG_POLL_MAX_WAIT` | `30` seconds — the cap on `wait` of the long-poll |
  | `:sse_keepalive` | `C3_SSE_KEEPALIVE_SECONDS` | `15` — seconds between two keepalive comments of the SSE stream |
  | `:join_lock_ips` | `C3_JOIN_LOCK_IPS` | `3` — distinct IPs with a wrong secret that lock joins |
  | `:unknown_code_limit` | `C3_UNKNOWN_CODE_LIMIT` | `5` — unknown codes per IP and day before a ban |
  | `:real_ip_header` | `C3_REAL_IP_HEADER` | `nil` — e.g. `x-forwarded-for`; unset = the peer address |
  | `:trusted_proxies` | `C3_TRUSTED_PROXIES` | loopback + private ranges |
  | `:ip_allowlist` | `C3_IP_ALLOWLIST` | `[]` — CIDRs that are never banned |
  | `:rate_limit_token` | `C3_RATE_LIMIT_TOKEN` | `120` requests per minute and token |
  | `:rate_limit_ip` | `C3_RATE_LIMIT_IP` | `300` requests per minute and IP |
  | `:max_body_bytes` | `C3_MAX_BODY_BYTES` | `65536` — a message body, in bytes; over it → `413` |
  | `:attachment_max_bytes` | `C3_ATTACHMENT_MAX_BYTES` | 5 MiB — one attached file |
  | `:attachments_message_max_bytes` | `C3_ATTACHMENTS_MESSAGE_MAX_BYTES` | 10 MiB — every file of one post together |
  | `:attachments_session_max_bytes` | `C3_ATTACHMENTS_SESSION_MAX_BYTES` | 50 MiB — every file of a session together |
  | `:attachments_per_message` | — | `10` files per post |
  | `:attachment_inline_max_bytes` | — | 1 MiB — the largest file `GET /v1/attachments/{id}?format=json` (and `c3_get_attachment`) returns inline |
  | `:attachments_dir` | `C3_ATTACHMENTS_DIR` | `nil` = `attachments/` next to the SQLite file (`/data/attachments` in the image) |
  | `:claim_ttl` | `C3_CLAIM_TTL_MINUTES` | 30 min, in seconds — a claim whose agent stays silent that long goes back to `open` |
  | `:mcp_allowed_origins` | `C3_MCP_ALLOWED_ORIGINS` | `[]` — browser origins allowed on `/mcp` (`https://app.example.com`); a request with any other `Origin` gets `403`. Agents send none |
  | `:admin_token` | `C3_ADMIN_TOKEN` | `nil` — the token of the admin pages (`/admin`), 32 characters or more; unset = no admin, `/admin` is a `404` |
  | `:metrics_token` | `C3_METRICS_TOKEN` | `nil` — bearer token of `GET /metrics` (Prometheus text), 32 characters or more; unset = `/metrics` is a `404` |
  | `:admin_session_ttl` | — | 12 h, in seconds — how long an admin login lasts |
  | `:last_seen_throttle` | — | `60` seconds between two `last_seen_at` writes of an agent, and between two `last_activity_at` writes of a session |
  | `:sweeper` | — | `true` — run `C3.Sweeper` (off in test, where the sandbox owns the DB) |
  """

  @defaults [
    tz: "Etc/UTC",
    secret_digits: 6,
    session_max_ttl: 7 * 24 * 3600,
    session_idle_ttl: 24 * 3600,
    session_closing_soon: 3600,
    retention_days: 30,
    long_poll_max_wait: 30,
    sse_keepalive: 15,
    join_lock_ips: 3,
    unknown_code_limit: 5,
    real_ip_header: nil,
    trusted_proxies: ~w(127.0.0.0/8 ::1/128 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7),
    ip_allowlist: [],
    rate_limit_token: 120,
    rate_limit_ip: 300,
    rate_limit_window_ms: 60_000,
    max_body_bytes: 65_536,
    attachment_max_bytes: 5 * 1024 * 1024,
    attachments_message_max_bytes: 10 * 1024 * 1024,
    attachments_session_max_bytes: 50 * 1024 * 1024,
    attachments_per_message: 10,
    attachment_inline_max_bytes: 1024 * 1024,
    attachments_dir: nil,
    claim_ttl: 30 * 60,
    mcp_allowed_origins: [],
    admin_token: nil,
    metrics_token: nil,
    admin_session_ttl: 12 * 3600,
    last_seen_throttle: 60,
    sweeper: true,
    sweep_interval_ms: 60_000
  ]

  @doc "The value of `key`, or its default."
  def get(key), do: Application.get_env(:c3, key, Keyword.fetch!(@defaults, key))

  @doc "The directory attachments are stored in: `:attachments_dir`, or `attachments/` next to the database."
  def attachments_dir do
    case get(:attachments_dir) do
      nil ->
        Path.join(Path.dirname(Application.fetch_env!(:c3, C3.Repo)[:database]), "attachments")

      dir ->
        dir
    end
  end

  @doc """
  The largest request body the parser accepts on the routes that carry attachments: the
  base64 of `attachments_message_max_bytes` plus room for the message itself.
  """
  def attachments_request_max_bytes do
    div(get(:attachments_message_max_bytes) * 4, 3) + get(:max_body_bytes) + 64 * 1024
  end

  @doc "Fails fast at boot on a setting that would only break at the first request."
  def validate! do
    tz = get(:tz)

    case DateTime.now(tz) do
      {:ok, _} -> :ok
      {:error, reason} -> raise ArgumentError, "C3_TZ #{inspect(tz)} is not usable: #{reason}"
    end

    digits = get(:secret_digits)

    unless digits in 6..8 do
      raise ArgumentError, "C3_SECRET_DIGITS must be between 6 and 8, got #{inspect(digits)}"
    end

    for key <- [:session_idle_ttl, :session_max_ttl, :long_poll_max_wait, :sse_keepalive],
        get(key) <= 0 do
      raise ArgumentError, "#{inspect(key)} must be positive, got #{inspect(get(key))}"
    end

    if get(:retention_days) < 0 do
      raise ArgumentError, "C3_RETENTION_DAYS must be 0 or more, got #{get(:retention_days)}"
    end

    for {key, var} <- [admin_token: "C3_ADMIN_TOKEN", metrics_token: "C3_METRICS_TOKEN"] do
      case get(key) do
        nil -> :ok
        token when byte_size(token) >= 32 -> :ok
        _ -> raise ArgumentError, "#{var} must be 32 characters or more (make secret)"
      end
    end

    for key <- [
          :attachment_max_bytes,
          :attachments_message_max_bytes,
          :attachments_session_max_bytes
        ],
        get(key) <= 0 do
      raise ArgumentError, "#{inspect(key)} must be positive, got #{inspect(get(key))}"
    end

    for key <- [:trusted_proxies, :ip_allowlist], cidr <- get(key) do
      C3.Security.CIDR.parse!(cidr)
    end

    :ok
  end
end
