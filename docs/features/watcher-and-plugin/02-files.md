---
doc: features/watcher-and-plugin/02-files
repo: c3
kind: feature-files
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Watcher and Claude Code Plugin — files

The code is split across two languages on purpose. The server decides which events concern an agent: `lib/c3/watch.ex:line` turns each event into one text line, or nothing. The plugin's shell scripts never parse JSON. They only need `sh` and `curl`, and they relay the server's lines as they are. People are often surprised that the watcher's filtering logic is in Elixir, not in `plugin/skills/c3/scripts/c3-watch.sh`. If you want to change what wakes an agent, edit `lib/c3/watch.ex:relevant`. If you change the line format, you must also update the script's `grep` for `^stop ` and `^cursor ` in `plugin/skills/c3/scripts/c3-watch.sh:cmd_wait`, and the agent-facing contract in `plugin/skills/c3/SKILL.md`.

**Owned globs:** `lib/c3/watch.ex`, `plugin/skills/c3/scripts/c3-watch.sh`, `plugin/skills/c3/scripts/c3-attach.sh`

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/watch.ex` | `C3.Watch.line/2` | util | Maps one feed event to a `<kind> <seq> <facts…>` line for one agent, or `nil` | A new event type should wake an agent; a line needs a new fact; the agent is woken by something it should not be |
| `lib/c3/watch.ex` | `relevant/3` (private) | util | One clause per event type, each guarded so the agent's own actions return `nil` | Changing who counts as a target of a request, cancellation or join |
| `lib/c3/watch.ex` | `for_me?/3` (private) | util | Target matching: `"any"` excludes the author, `"label:x"` matches `me.label`, anything else matches by name | Adding a new kind of request addressing |
| `lib/c3/watch.ex` | `title/2`, `@title_max` | util | Appends the thread title (control characters stripped, `"` replaced by `'`, cut to 80) only for `request`/`answer`/`cancelled` | Lines break the shell parsing; titles need to be longer or shorter |
| `lib/c3/watch.ex` | `files/1` (private) | util | Adds `files <n>` when the payload has attachments | Showing more attachment info in the wake line |

Traps:
- In `:thread_opened`, a thread with several targets produces **one** line, for the first target that matches (`Enum.find`). It does not produce one line per request.
- Only `AG1` gets `joined` lines: the clause matches on `%{number: 1}`.
- Every agent gets `security` and `closing_soon` lines, whoever caused them. These clauses have no `by != me.name` guard.

## Scripts (plugin)

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `plugin/skills/c3/scripts/c3-watch.sh` | `cmd_wait` | script | Long-polls `/v1/sessions/<code>/watch`, saves the cursor after every poll, exits 0 on the first news, on `idle`, or on `stop` | Changing the exit conditions, the backoff, or the `relaunch:` line |
| `plugin/skills/c3/scripts/c3-watch.sh` | `cmd_save` | script | Reads the token from stdin and writes the mode-600 state file. A new token starts the cursor at the session's current end (`current_end`) | Changing where the watcher starts reading, or the state file format |
| `plugin/skills/c3/scripts/c3-watch.sh` | `write_state`, `state_file`, `STATE_DIR` | script | Writes the state atomically to `$C3_STATE_DIR` (default XDG state dir). Rejects keys containing `/` or `..` | Moving the state location; adding a state field (`c3-attach.sh` reads the same file) |
| `plugin/skills/c3/scripts/c3-watch.sh` | `poll` | script | One `curl`. Passes the token as a header config on stdin (`-K -`), never in argv | Changing auth or timeouts (`--max-time` = wait + 15) |
| `plugin/skills/c3/scripts/c3-watch.sh` | `cmd_forget`, `cmd_list` | script | Deletes a state file; lists the keys (never the tokens) | Cleanup after leaving or closing a session |
| `plugin/skills/c3/scripts/c3-attach.sh` | `cmd_send` | script | `post` to `/v1/threads/<t>/messages` or `open` to `/v1/sessions/<code>/threads`, with each file sent as base64 | Adding a flag that maps to a request field |
| `plugin/skills/c3/scripts/c3-attach.sh` | `build`, `json_string` | script | Builds the JSON body in a temp file with `awk`, so file contents never reach argv or the agent | Bodies with unusual characters are rejected; large files fail |
| `plugin/skills/c3/scripts/c3-attach.sh` | `cmd_get` | script | Downloads `/v1/attachments/<id>` to a path. Deletes the file and exits 1 on an HTTP error | Changing how downloads are named or stored |

Traps:
- The watcher always exits 0, including for `stop` and for HTTP 401/403/404/410. Exit 2 means a usage error. The output lines carry the meaning, not the exit code.
- `c3-attach.sh` depends on the state file that `c3-watch.sh save` writes. It has no `save` of its own. Both scripts honor `C3_URL` as an override.
- The usage text is printed with `sed -n '7,10p'` (watch) and `sed -n '7,9p'` (attach) over each script's own header. If you edit the header comment, the help output shifts.
- Tunables are environment variables that only `c3-watch.sh` reads: `C3_WATCH_MAX_SECONDS`, `C3_WATCH_POLL`, `C3_WATCH_RETRY`.

## Plugin manifest and contract

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `plugin/skills/c3/SKILL.md` | `allowed-tools` | constant | The agent's contract: how to save, wait, relaunch and attach. Pre-allows both scripts | Any change to script arguments or line kinds |
| `plugin/.claude-plugin/plugin.json` | `version` | constant | Pinned plugin version | Any change under `plugin/`: bump it to the `mix.exs` version, or `claude plugin update` skips the change |
| `plugin/.mcp.json` | `mcpServers` | constant | Points the MCP client at `${user_config.server_url}/mcp` | Moving the MCP endpoint ([mcp-server](../mcp-server/)) |

## Tests

| Path | Covers |
|---|---|
| `test/c3/watch_script_test.exs` | `c3-watch.sh` subcommands against a running server: save, wait, cursor persistence, stop |
| `test/c3/attach_script_test.exs` | `c3-attach.sh` post/open/get round-trips |
| `test/c3_web/controllers/v1/watch_test.exs` | The `/watch` endpoint and the lines `C3.Watch.line/2` produces |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3_web/controllers/v1/event_controller.ex:watch_after` (the long-poll loop that keeps waiting while the events belong to someone else) | [event-feed](../event-feed/) |
| `lib/c3_web/router.ex` route `/sessions/:code/watch` | [event-feed](../event-feed/) |
| Event payloads (`resolved_for`, `requests`, `claimed_by`) that `lib/c3/watch.ex` reads | [threads-and-requests](../threads-and-requests/) |
| Attachment storage and the `/v1/attachments/:id` endpoint | [attachments](../attachments/) |
| Join failure and lock events | [join-security](../join-security/) |
| Close, closing-soon and revoke events | [session-lifecycle](../session-lifecycle/) |
