---
doc: architecture/06-testing
repo: c3
kind: architecture
anchored_to: e99b2ae
generated: 2026-10-02
---
# Testing

The suite is plain ExUnit. It covers the contexts under `lib/c3/`, the REST and MCP doors under `lib/c3_web/`, and the two shell scripts the plugin ships, `plugin/skills/c3/scripts/c3-watch.sh` and `plugin/skills/c3/scripts/c3-attach.sh`. Its job is to keep the two doors (`/v1` and `/mcp`) telling the same story, and to keep the scripts working against a real server. That is why some of the tests are slower and more global than a typical Phoenix suite.

## How it works

`test/test_helper.exs` starts ExUnit and puts the Ecto sandbox in `:manual` mode. It also wipes `C3.Config.attachments_dir()` (`lib/c3/config.ex:attachments_dir`) before each run. Attachment files sit on disk, so a sandbox rollback does not remove them.

Two case templates set up the sandbox, and both go through `test/support/data_case.ex:setup_sandbox`. It calls `Ecto.Adapters.SQL.Sandbox.start_owner!` with `shared: not tags[:async]`, so a non-async test shares one connection with every process it spawns. That matters for `Task.async` long-poll tests and for the Bandit listener.

- `test/support/data_case.ex:C3.DataCase` is for context tests.
- `test/support/conn_case.ex:C3Web.ConnCase` is for HTTP tests. Each test gets a `conn` that already has a fresh `remote_ip` from `unique_ip`.

**Database tests run synchronously on purpose.** With the SQLite sandbox, async tests timed out waiting for the single writer's lock. SQLite allows one writer at a time, the rule `AGENTS.md` also states for row locking. Only tests that never touch the database are `async: true`:

- `test/c3/security/cidr_test.exs`
- `test/c3/credentials_test.exs`
- `test/c3/local_time_test.exs`
- `test/c3/threads/derivation_test.exs`
- `test/c3_web/controllers/error_json_test.exs`
- `test/c3_web/controllers/error_html_test.exs`

**IP state is global.** Bans are cached in a global ETS table (`lib/c3/security/ban_cache.ex`), and the sandbox does not roll ETS back. `test/support/conn_case.ex:unique_ip` hands out addresses from 198.18.0.0/15, derived from `System.unique_integer`, so one test's ban never blocks another. A test that needs several clients builds each one with `with_ip(build_conn(), unique_ip())`. The `fresh_conn` helpers in `test/c3_web/controllers/v1/session_controller_test.exs` and `test/c3/watch_script_test.exs` do exactly this. `ip_string` turns the tuple into the string form C3 stores, for assertions against stored rows.

**Plugin scripts run against a real Bandit.** `test/c3/watch_script_test.exs` and `test/c3/attach_script_test.exs` work the same way:

1. Find a free port by opening `:gen_tcp.listen(0, …)` and closing it.
2. Start `{Bandit, plug: C3Web.Endpoint, ip: {127, 0, 0, 1}, port: port}` with `start_supervised!`.
3. Run the real shell script from `plugin/skills/c3/scripts/`, setting `C3_STATE_DIR` to a temporary directory and `C3_WATCH_POLL` to a short value.

Both files carry `@moduletag :watcher` and need `sh` and `curl` on the host.

**REST↔MCP parity.** `test/c3_web/mcp/parity_test.exs` runs one `@scenario` twice: once through `/v1` and once through `/mcp`, each from its own IP. It then compares the two transcripts of `{status, body}`, after `mask` replaces everything in `@masked` with `"<masked>"`:

- codes, secrets and tokens
- the `*_at` timestamps
- `ip`, `subject` and `banned_until`
- integer `id`s
- any `"C3-…"` string

The REST route for each tool is written out by hand in `@routes`, so the test does not trust `lib/c3_web/mcp/tools.ex` to do the mapping. `learn` carries forward values that later steps refer to: `:code`, `:secret`, AG2's token and the attachment id. `test/support/mcp_helpers.ex` provides `mcp` (a JSON-RPC call), `tool` (a `tools/call`) and `meta` (the protocol-version header).

## The pieces

| Path | Export | Role |
|---|---|---|
| `test/test_helper.exs` | — | Manual sandbox; wipes the attachments directory each run |
| `test/support/data_case.ex` | `setup_sandbox`, `errors_on` | Sandbox owner (shared unless the test is async); changeset errors as a map |
| `test/support/conn_case.ex` | `unique_ip`, `with_ip`, `ip_string` | Gives each test its own client IP, because ban state is global ETS |
| `test/support/mcp_helpers.ex` | `mcp`, `tool`, `meta` | JSON-RPC and tool calls to `/mcp` |
| `test/support/fixtures/c3_fixtures.ex` | `session_fixture`, `agent_fixture`, `thread_fixture`, `request_fixture`, `note_fixture`, `message_struct`, `event_fixture`, `join_failure_fixture`, `ip_ban_fixture`, `idempotency_key_fixture` | Insert rows through each schema's changeset; unique fields come from `unique_int` |
| `test/c3_web/mcp/parity_test.exs` | `@scenario`, `@routes`, `@masked` | One scenario through both doors, compared after masking |
| `test/c3/watch_script_test.exs` | `@moduletag :watcher` | `c3-watch.sh` against a live Bandit |
| `test/c3/attach_script_test.exs` | `@moduletag :watcher` | `c3-attach.sh` (and the watcher) against a live Bandit |
| `test/c3_web/controllers/v1/watch_test.exs` | — | The `/watch` long-poll, using `Task.async` |

## How a feature uses it

An HTTP test uses `C3Web.ConnCase` without `async`. Each extra client gets its own IP:

```elixir
use C3Web.ConnCase

defp fresh_conn, do: with_ip(build_conn(), unique_ip())

created = fresh_conn() |> post(~p"/v1/sessions", %{}) |> json_response(201)
```

A test that skips `with_ip` for a second client shares the default conn's IP. Any ban or join-failure count it triggers then lands on that IP.

A new MCP tool needs an entry in `@routes` and a step in `@scenario`, or parity never covers it. A new response field that differs between runs needs a place in `@masked`, or the parity test fails on an unmasked diff.

## Rules

1. Never add `async: true` to a test that touches `C3.Repo`. It brings back the SQLite write-lock timeouts, and they show up as intermittent failures.
2. Every simulated client gets `unique_ip()`. Reusing an IP leaks bans between tests through the global ETS cache, so failures depend on test order.
3. Fixtures go through changesets (`test/support/fixtures/c3_fixtures.ex`). Raw inserts skip the validations the code under test relies on.
4. `make precommit` runs `mix precommit` (`mix.exs:precommit`): `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`. It is pinned to `MIX_ENV=test` through `cli/0:preferred_envs`. A compiler warning fails it.
5. CI (`.github/workflows/ci.yml`) has two jobs:
   - The `test` job runs `make precommit`, then `git diff --exit-code`. An unformatted commit, or a stale `mix.lock`, fails CI even though precommit itself passed.
   - The `docker` job runs `make docker-smoke`.

## Gotchas

- The moduledocs of `test/support/data_case.ex` and `test/support/conn_case.ex` are the Phoenix generator's text and suggest `async: true`. Ignore that advice here.
- `:watcher` is a tag, not an exclusion. The script tests run in a plain `mix test` and in CI, so the host needs `sh` and `curl`. `make test-watcher` runs just those three files (`watch_test`, `watch_script_test`, `attach_script_test`).
- The free port comes from opening a socket and closing it again, so another process could grab it before Bandit binds it. It is rare, and it fails at `start_supervised!`.
- Bandit serves requests from its own processes. They see the test's data only because the sandbox is shared (non-async), which is one more reason those tests cannot be async.
- Attachments written during a run stay on disk until the next run starts. Nothing removes them per test.
- `make plugin-validate` (`claude plugin validate`) is not part of `precommit` or CI.

## Who uses it

| Feature | Uses it for |
|---|---|
| Sessions and joins (`lib/c3/sessions/`) | `unique_ip` for ban, escalation and join-lock tests (`test/c3_web/controllers/v1/session_controller_test.exs`, `test/c3/security/escalation_test.exs`) |
| Threads (`lib/c3/threads/`) | Fixtures and sandbox (`test/c3/threads_test.exs`, `test/c3/threads/writes_test.exs`) |
| MCP door (`lib/c3_web/mcp/`) | `mcp_helpers` and the parity test |
| Plugin (`plugin/skills/c3/scripts/`) | Script tests against a live Bandit |
| Attachments | The directory wipe in `test_helper.exs` (`test/c3/attachments_test.exs`) |
