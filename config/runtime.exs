import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/c3 start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :c3, C3Web.Endpoint, server: true
end

config :c3, C3Web.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# C3 settings: only the variables that are set override the defaults in C3.Config.
csv = fn value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) end

c3_env = [
  tz: {"C3_TZ", & &1},
  secret_digits: {"C3_SECRET_DIGITS", &String.to_integer/1},
  session_max_ttl: {"C3_SESSION_MAX_TTL_HOURS", &(String.to_integer(&1) * 3600)},
  session_idle_ttl: {"C3_SESSION_IDLE_TTL_HOURS", &(String.to_integer(&1) * 3600)},
  session_closing_soon: {"C3_SESSION_CLOSING_SOON_MINUTES", &(String.to_integer(&1) * 60)},
  retention_days: {"C3_RETENTION_DAYS", &String.to_integer/1},
  long_poll_max_wait: {"C3_LONG_POLL_MAX_WAIT", &String.to_integer/1},
  sse_keepalive: {"C3_SSE_KEEPALIVE_SECONDS", &String.to_integer/1},
  join_lock_ips: {"C3_JOIN_LOCK_IPS", &String.to_integer/1},
  unknown_code_limit: {"C3_UNKNOWN_CODE_LIMIT", &String.to_integer/1},
  secret_tolerance: {"C3_SECRET_TOLERANCE", &String.to_integer/1},
  ipv6_prefix: {"C3_IPV6_PREFIX", &String.to_integer/1},
  real_ip_header: {"C3_REAL_IP_HEADER", &String.downcase(String.trim(&1))},
  trusted_proxies: {"C3_TRUSTED_PROXIES", csv},
  ip_allowlist: {"C3_IP_ALLOWLIST", csv},
  rate_limit_token: {"C3_RATE_LIMIT_TOKEN", &String.to_integer/1},
  rate_limit_ip: {"C3_RATE_LIMIT_IP", &String.to_integer/1},
  max_body_bytes: {"C3_MAX_BODY_BYTES", &String.to_integer/1},
  knowledge_summary_max_bytes: {"C3_KNOWLEDGE_SUMMARY_MAX_BYTES", &String.to_integer/1},
  attachment_max_bytes: {"C3_ATTACHMENT_MAX_BYTES", &String.to_integer/1},
  attachments_message_max_bytes: {"C3_ATTACHMENTS_MESSAGE_MAX_BYTES", &String.to_integer/1},
  attachments_session_max_bytes: {"C3_ATTACHMENTS_SESSION_MAX_BYTES", &String.to_integer/1},
  attachments_dir: {"C3_ATTACHMENTS_DIR", &String.trim/1},
  claim_ttl: {"C3_CLAIM_TTL_MINUTES", &(String.to_integer(&1) * 60)},
  mcp_allowed_origins: {"C3_MCP_ALLOWED_ORIGINS", csv},
  admin_token: {"C3_ADMIN_TOKEN", &String.trim/1},
  metrics_token: {"C3_METRICS_TOKEN", &String.trim/1}
]

for {key, {var, parse}} <- c3_env, value <- [System.get_env(var)], value not in [nil, ""] do
  config :c3, [{key, parse.(value)}]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/c3/c3.db
      """

  config :c3, C3.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    # Writers take the lock up front instead of failing on a read-to-write upgrade.
    default_transaction_mode: :immediate

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :c3, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :c3, C3Web.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :c3, C3Web.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :c3, C3Web.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
