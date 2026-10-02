# AGENTS.md — C3

C3 (Central Context Coordinator) is a Phoenix service for stateful messaging between AI agents:
sessions joined with a code + security number, threads whose status is derived from open requests,
a watcher-friendly long-poll event feed, and a remote MCP endpoint.

- Context map: start at [`docs/00-INDEX.md`](docs/00-INDEX.md) before planning a change (refresh with sk-context).
- Phoenix/LiveView conventions for this codebase: the sections below.
- Every command goes through the `Makefile` (`make` lists them). Run `make precommit` before
  finishing a change; `make docker-smoke` when touching the Dockerfile, release or runtime config.
- Database: SQLite via `ecto_sqlite3`. Keep queries portable to Postgres.
- This repository is public: deployment docs and configs stay generic (`example.com`,
  `<HOST_PORT>`, "the reverse proxy"). No real hostnames, IPs or infrastructure details.
- Versions: a release bumps `version` in `mix.exs` (tag `vX.Y.Z`, `## X.Y.Z — date` in
  `CHANGELOG.md`); any change under `plugin/` also bumps `plugin/.claude-plugin/plugin.json` to
  that same number — the plugin's version is pinned, so `claude plugin update` skips it otherwise.

## Project conventions

- **Contexts own the rules.** `lib/c3/` (`Sessions`, `Threads`, `Security`, `Attachments`, …)
  holds every check and write; controllers, the MCP layer and the admin only call them.
- **REST and MCP cannot drift.** A tool call runs its REST request in-process through the router
  (`C3Web.MCP.Dispatch`), so a new feature is a REST route first and a tool entry in
  `C3Web.MCP.Tools` second. `test/c3_web/mcp/parity_test.exs` keeps them aligned.
- **Errors** go through `C3Web.ApiError` (`{"error": {"code", "message", "details"?}}`) and the
  `FallbackController`; a new error code needs its row in that module and in `docs/api.md`.
- **Events** are written with `Events.append!` inside the same transaction as the change they
  describe; a new event type needs a migration that rebuilds `events` (see the existing ones).
- **Migrations** are tested up/down/up on a database with data.
- **ETS state** (`BanCache`, `RateLimiter`, idempotency marks, `Metrics`) is a cache or a
  counter; the database is the source of truth, and losing ETS on a restart must be harmless.
- **Configuration** is read with `C3.Config.get/1`; a new `C3_*` variable gets its row in the
  `C3.Config` moduledoc and in `docs/deploy.md`.
- **Public docs** (`docs/api.md`, `docs/mcp.md`, `docs/deploy.md`, `README.md`) change in the same
  commit as the behaviour, and user-visible changes get a line in `CHANGELOG.md`.
- **HTTP client:** `Req`. Never `:httpoison`, `:tesla` or `:httpc`.

## Elixir

- No index access on lists (`list[i]`): use `Enum.at/2` or pattern matching.
- Bind the result of `if`/`case`/`cond`; rebinding inside the block is lost.
- One module per file. No map access (`struct[:field]`) on structs; use `struct.field` or
  `Ecto.Changeset.get_field/2`.
- Never `String.to_atom/1` on user input.
- Predicates end in `?` (`is_` is for guards).
- Date and time come from the standard library (`DateTime`, `Date`, `Calendar`).

## Ecto

- Preload associations that a view or a JSON renderer reads.
- Fields set by the code (`session_id`, `agent_id`, hashes) are never in `cast`.
- `:string` for text columns; `validate_number/2` has no `:allow_nil`.
- Generate migrations with `mix ecto.gen.migration <name>`.
- Keep queries portable to Postgres: no SQLite-only functions, and lock a row with an
  `update_all` inside the transaction (see `Threads.lock_thread!/2`) instead of relying on
  SQLite's single writer.

## Tests

- `make test`; one file with `mix test test/path_test.exs`, the last failures with
  `mix test --failed`. `make test-watcher` covers `/watch` and the plugin's shell scripts.
- Start processes with `start_supervised!/1`.
- No `Process.sleep/1`: monitor and `assert_receive {:DOWN, …}`, or `:sys.get_state/1` to
  synchronize.

## Admin LiveView

The admin (`lib/c3_web/live/admin/`) is the only UI: a few operator pages, not a product.

- Templates start with `<Layouts.app flash={@flash} ...>`; `<.flash_group>` lives only in
  `layouts.ex`.
- Use the `core_components.ex` helpers (`<.input>`, `<.icon name="hero-…">`, `<.button>`).
  Styling is Tailwind v4 with the vendored daisyUI theme (`assets/css/app.css`); keep it plain.
- Templates are HEEx: `{...}` in attributes and text, `<%= ... %>` only for block constructs;
  `:for` / `:if` instead of `Enum.each` and inline `if`; class lists as `class={[...]}`.
- Tests use `Phoenix.LiveViewTest` with element ids (`has_element?/2`, `element/2`), not raw HTML.
