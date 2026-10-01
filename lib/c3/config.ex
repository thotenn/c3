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
  | `:claim_ttl` | `C3_CLAIM_TTL_MINUTES` | 30 min, in seconds — a claim whose agent stays silent that long goes back to `open` |
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
    claim_ttl: 30 * 60,
    last_seen_throttle: 60,
    sweeper: true,
    sweep_interval_ms: 60_000
  ]

  @doc "The value of `key`, or its default."
  def get(key), do: Application.get_env(:c3, key, Keyword.fetch!(@defaults, key))

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

    for key <- [:trusted_proxies, :ip_allowlist], cidr <- get(key) do
      C3.Security.CIDR.parse!(cidr)
    end

    :ok
  end
end
