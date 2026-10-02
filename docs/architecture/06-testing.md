---
doc: architecture/06-testing
repo: c3
kind: architecture
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Testing

The suite is plain ExUnit on top of Phoenix's `DataCase`/`ConnCase` templates. Four things make it different from a stock Phoenix app. Database tests run serially against SQLite. Client IPs are randomised per test because bans and rate limits live in global ETS. The plugin's shell scripts run against a real HTTP listener. A parity test drives the REST API and the MCP endpoint through the same scenario and checks that the two give the same results. `make precommit` is the gate both locally and in CI.

## How it works

**Sandbox, and why database tests are not async.** `test/test_helper.exs` puts `C3.Repo` in `:manual` sandbox mode. `test/support/data_case.ex:setup_sandbox` starts an owner with `shared: not tags[:async]`, so a test that is not async shares its connection with every process it spawns. No database test declares `async: true`. On SQLite, concurrent sandboxed transactions contend for the single write lock and time out, so the database suites run one at a time on purpose. Only pure-function suites are async: `test/c3/threads/derivation_test.exs`, `test/c3/credentials_test.exs`, `test/c3/security/cidr_test.exs`, `test/c3/local_time_test.exs` and the two error-view tests. These use `ExUnit.Case`, not `DataCase`. Shared mode is also what lets the Bandit-served requests in the script tests (below) see the test's data.

**Per-test client IPs.** Bans and per-IP counters are global ETS state, which the sandbox does not roll back. `test/support/conn_case.ex:unique_ip` hands out a fresh address from `198.18.0.0/15` for every `conn`. Helpers build extra clients with `test/support/conn_case.ex:with_ip`, and `test/support/conn_case.ex:ip_string` gives the stored string form. `config/test.exs` raises `rate_limit_ip` to `100_000` so unrelated tests never trip the limit. The rate-limit tests lower it themselves.

**Global config swaps.** Several suites change `Application` env for one test and restore the previous value in `on_exit`. Examples are `test/c3_web/controllers/v1/f8_controller_test.exs` (metrics token, attachments), `test/c3_web/controllers/v1/event_controller_test.exs` and `test/c3_web/plugs/security_config_test.exs`. These suites declare `async: false` explicitly.

**Attachments on disk.** Files written by attachments survive sandbox rollbacks. `test/test_helper.exs` runs `File.rm_rf!(C3.Config.attachments_dir())` at startup. In test, that directory is under the ignored `tmp/` (set in `config/test.exs`).

**Plugin scripts against a real server.** `test/c3/watch_script_test.exs` and `test/c3/attach_script_test.exs` run the plugin's shell scripts, such as `plugin/skills/c3/scripts/c3-watch.sh`, through `System.cmd("sh", …)`. They need `sh` and `curl` on the machine. To serve requests, each test binds a free port with `:gen_tcp.listen(0, …)` and starts `{Bandit, plug: C3Web.Endpoint, …}` with `start_supervised!`. The endpoint itself keeps `server: false`. Each test gets its own state dir under `System.tmp_dir!()` through `C3_STATE_DIR`, and the dir is removed `on_exit`. Some watcher tests start the listener late on purpose, to check that the script survives an unreachable server. Both files carry `@moduletag :watcher`.

**REST↔MCP parity.** `test/c3_web/mcp/parity_test.exs` runs one scenario twice: once through `/v1`, using the hand-written `@routes` map, and once through `/mcp`, using `test/support/mcp_helpers.ex:tool`. Each run comes from its own IP. Values that differ between runs are replaced with `"<masked>"` by `mask`, using the keys in `@masked` plus integer `id`s. The two masked transcripts must be equal. The `@routes` map is written out by hand so the test does not depend on `C3.MCP.Tools` getting the mapping right.

## The pieces

| Path | Export | Role |
|---|---|---|
| `test/test_helper.exs` | — | Sets manual sandbox mode and wipes the attachments dir. |
| `test/support/data_case.ex` | `C3.DataCase.setup_sandbox` | Starts the sandbox owner; shared mode when the test is not async. |
| `test/support/data_case.ex` | `errors_on` | Turns changeset errors into a map of messages. |
| `test/support/conn_case.ex` | `unique_ip`, `with_ip`, `ip_string` | Gives every conn a unique client IP. |
| `test/support/mcp_helpers.ex` | `mcp`, `tool`, `meta` | JSON-RPC calls to `/mcp` with the headers and `_meta` a `2026-07-28` client sends. Pass `nil` in `headers` to drop a header. |
| `test/support/fixtures/c3_fixtures.ex` | `session_fixture`, `agent_fixture`, `thread_fixture`, `request_fixture`, `note_fixture`, `event_fixture`, `ip_ban_fixture`, `join_failure_fixture`, `idempotency_key_fixture`, `message_struct` | Inserts rows directly, bypassing the contexts. |
| `test/c3_web/mcp/parity_test.exs` | `@routes`, `@masked`, `mask` | Checks REST and MCP give the same results. |
| `test/c3/watch_script_test.exs` | `free_port`, `serve` | Tests the watcher script against a real Bandit listener. |
| `test/c3/attach_script_test.exs` | — | Tests the attach script against a real Bandit listener. |
| `test/c3/db_constraints_test.exs` | — | Database-level constraints. |

## How a feature uses it

A database or HTTP test uses a case template without `async: true`. Every extra client gets its own IP:

```elixir
use C3Web.ConnCase

defp fresh_conn, do: with_ip(build_conn(), unique_ip())

test "…" do
  created = fresh_conn() |> post(~p"/v1/sessions", %{}) |> json_response(201)
end
```

If you skip `unique_ip` and reuse one IP across many requests, a ban or the rate limit set off by one test can block a later one.

## Rules

1. Never add `async: true` to a suite that uses `C3.DataCase` or `C3Web.ConnCase`. On SQLite, the sandbox write lock times out intermittently. It also turns off shared mode, so Bandit-served requests in the script tests can no longer see the test's data.
2. Every new MCP tool or REST route goes into `@routes` and into the parity scenario in `test/c3_web/mcp/parity_test.exs`. Without that, the two doors can drift apart unnoticed.
3. A value that legitimately differs between two runs (a new token, a timestamp, a code) goes into `@masked`. Without that, the parity test fails on a correct change.
4. A test that changes `Application` env restores the previous value in `on_exit` and declares `async: false`. Otherwise the change leaks into other tests.
5. A test that needs a background job calls the job directly. `config/test.exs` sets `sweeper: false` because the sweeper would hit the database outside the sandbox.

## Gotchas

- `make precommit` runs `mix precommit`: `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test` (alias in `mix.exs`, run with `MIX_ENV=test`). It formats and unlocks in place. The CI job in `.github/workflows/ci.yml` runs `make precommit` and then `git diff --exit-code`, so an unformatted commit passes locally but fails in CI.
- CI has a second job, `make docker-smoke`, which builds the image and smoke-tests it. That job is not part of `make precommit`.
- `make test-watcher` runs only the watch and attach suites. The `:watcher` tag is not excluded by default, so plain `mix test` runs them too and needs `sh` and `curl`.
- `config/test.exs` sets cheap Argon2 parameters (`t_cost: 1, m_cost: 8`). Timing-sensitive tests do not reflect production cost.
- The admin pages are on in test (`admin_token` set). The 404 case in `test/c3/admin_test.exs` turns them off itself.
- The fixtures insert rows directly and skip context validations and events. Use the context functions or the HTTP API when the test depends on events being emitted.

## Who uses it

| Feature | Uses it for |
|---|---|
| Sessions / credentials | `test/c3/sessions_test.exs`, `test/c3/sessions/lifecycle_test.exs`, `test/c3_web/controllers/v1/session_controller_test.exs`: per-IP isolation for join failures and locks. |
| Threads | `test/c3/threads_test.exs`, `test/c3/threads/writes_test.exs`, `test/c3_web/controllers/v1/thread_controller_test.exs`. |
| Events / watch | `test/c3/events_feed_test.exs`, `test/c3_web/controllers/v1/event_controller_test.exs`, `test/c3_web/controllers/v1/watch_test.exs`. |
| MCP | `test/c3_web/mcp/protocol_test.exs`, `test/c3_web/mcp/parity_test.exs`. |
| Plugin | `test/c3/watch_script_test.exs`, `test/c3/attach_script_test.exs`. |
| Attachments, rotation, metrics | `test/c3/attachments_test.exs`, `test/c3_web/controllers/v1/f8_controller_test.exs`. |
| Admin | `test/c3/admin_test.exs`, `test/c3_web/live/admin_live_test.exs`. |
| Security | `test/c3/security_test.exs`, `test/c3_web/plugs/security_config_test.exs`. |
