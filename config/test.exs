import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :c3, C3.Repo,
  database: Path.expand("../c3_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :c3, C3Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "VHtnTJ8/ZshSCEBfZC9vkRoP4GcDNGyK+E3yHqxfqBuyvsq5DQxTJ+glt14KBxkO",
  server: false

# Cheap Argon2 parameters: the cost only matters against an offline attack.
config :argon2_elixir, t_cost: 1, m_cost: 8

# Each test gets its own client IP (see ConnCase); a high per-IP limit keeps unrelated tests
# from tripping it. The rate-limit tests lower it themselves.
config :c3, rate_limit_ip: 100_000

# The sweeper would touch the DB outside the sandbox; tests call its jobs directly.
config :c3, sweeper: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
