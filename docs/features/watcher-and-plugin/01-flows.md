---
doc: features/watcher-and-plugin/01-flows
repo: c3
kind: feature-flows
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Watcher and Claude Code Plugin — flows

This feature has five flows. Two are local and set up or remove state: saving the watcher state and forgetting it. One is the watcher's long-poll loop. In that loop the server decides what concerns the agent and the shell script only relays lines. The last two move attachments from disk to the server and back, so the file content never passes through the agent's context. All three scripts share one state file per (session, agent) key.

## Flow: Save the watcher state after creating or joining a session

**Entry:** `sh c3-watch.sh save <url> <code> <name>` (token on stdin)

1. **Trigger** — the agent pipes its token into `save` right after `c3_create_session` / `c3_join_session` · `plugin/skills/c3/scripts/c3-watch.sh:cmd_save`
2. **Guard** — the key `<code>-<name>` is rejected if it is empty or contains `/` or `..`. A missing token on stdin is exit 2 · `plugin/skills/c3/scripts/c3-watch.sh:state_file`
3. **Logic** — if a state file already exists with the same token, its cursor `after` is kept. Otherwise the cursor starts at the session's current end. To find that end, the script pages `/watch` with `wait=0` until the cursor stops moving · `plugin/skills/c3/scripts/c3-watch.sh:current_end`
4. **Persist** — `url, code, name, token, after` are written to a temp file under `umask 077`, then `mv`'d over the state file. The default directory is `$C3_STATE_DIR` → `$XDG_STATE_HOME/c3` → `$HOME/.local/state/c3` · `plugin/skills/c3/scripts/c3-watch.sh:write_state`
5. **Respond** — prints the key (`C3-XXXX-XXXX-AG2`) · `plugin/skills/c3/scripts/c3-watch.sh:cmd_save`

**Touch this flow when:** the state file layout changes, the default state directory moves, or the "start at the end" rule changes.
**Breaks when:** the server cannot be reached during `save`. `current_end` then silently returns `0`, so the first `wait` replays the whole session's history as news. Also, the cursor starts at the end, so anything that was already waiting is reported only if the agent reads `c3_inbox` after saving. This is the order `plugin/skills/c3/SKILL.md` requires.

## Flow: Wait for news concerning me (the watcher)

**Entry:** `sh c3-watch.sh wait <key>` run with `run_in_background` → `GET /v1/sessions/<code>/watch?after=<seq>&wait=<s>`

1. **Trigger** — Claude Code starts `wait` in the background. It loops until `C3_WATCH_MAX_SECONDS` (default 6000) has passed · `plugin/skills/c3/scripts/c3-watch.sh:cmd_wait`
2. **Guard** — the token goes to curl as a `-K -` config header on stdin, never on the command line. Server-side, the bearer token resolves `current_session` / `current_agent` · `plugin/skills/c3/scripts/c3-watch.sh:poll`, `lib/c3_web/controllers/v1/event_controller.ex:watch`
3. **Logic** — the server holds the request until events arrive or the deadline passes. The deadline is `min(wait, :long_poll_max_wait)`. Each event goes through `C3.Watch.line/2`. If a batch has no line for this agent and time remains, the server advances the cursor and waits again · `lib/c3_web/controllers/v1/event_controller.ex:watch_after`
4. **Logic (relevance)** — an event concerns `me` if it is one of these: a request to its name, its `label:`, or `any` from someone else; an answer whose `resolved_for` contains it; a cancellation of a request it held, or of an unclaimed request addressed to it; its own claim expiring; `joined` (only for agent `number: 1`); `security`; `closing_soon`; `stop`. An event the agent caused itself never matches. For a thread opened to several targets, only the first target that is me produces a line · `lib/c3/watch.ex:relevant`, `lib/c3/watch.ex:for_me?`
5. **Persist** — the script stores the returned `cursor <seq>` in the state file after every poll that moved it, so a restart loses nothing · `plugin/skills/c3/scripts/c3-watch.sh:write_state`
6. **Respond** — the script prints `c3 <code> <name>`, then the event lines, then a `relaunch:` line, and exits. The `relaunch:` line is left out when a line starts with `stop`. HTTP `401/403/404/410` become a synthesized `stop http_<status> <body…>`. When the time runs out, the script prints `idle no news for … s` and a `relaunch:` line. Every case exits 0 · `plugin/skills/c3/scripts/c3-watch.sh:relaunch`

**Touch this flow when:** a new event type should wake agents (add a `relevant/3` clause in `lib/c3/watch.ex`, then add a row to the table in `plugin/skills/c3/SKILL.md`), the line format changes, or retry and backoff behaviour changes.
**Breaks when:**
- **The agent does not relaunch after a `relaunch:` line.** Nothing wakes it anymore.
- **Free text gets into a line other than the last one.** Line facts are space-joined with no escaping, and the script only greps for `^cursor ` and `^stop `. The thread title is the only free text: it is quoted last, with control characters and whitespace collapsed, `"` turned into `'`, and a cut at `@title_max` (80) (`lib/c3/watch.ex:title`).
- **`relevant/3` lacks a self-exclusion guard.** A new clause without the `by != me.name` guard wakes the agent for its own actions.
- **Network errors.** These and 5xx responses retry with doubling backoff capped at 60 s, and a 429 sleeps 30 s. A dead server therefore looks like silence until the time limit, not like an error.
- **`C3_URL` is set.** It overrides the URL used for polling, but `write_state` re-persists the URL from the file, so the override never sticks.

## Flow: Forget or list saved watcher state

**Entry:** `sh c3-watch.sh forget <key>` / `sh c3-watch.sh list`

1. **Trigger** — after `c3_leave` / `c3_close_session`, or after a `stop` line · `plugin/skills/c3/scripts/c3-watch.sh:cmd_forget`
2. **Guard** — the same key validation applies · `plugin/skills/c3/scripts/c3-watch.sh:state_file`
3. **Persist** — `rm -f` of the state file. Nothing is sent to the server · `plugin/skills/c3/scripts/c3-watch.sh:cmd_forget`
4. **Respond** — `list` prints `key url=… after=…` per file and skips `*.tmp.*`. Tokens are never printed · `plugin/skills/c3/scripts/c3-watch.sh:cmd_list`

**Touch this flow when:** new fields are added to the state file that `list` should show (never the token).
**Breaks when:** `forget` runs before `c3-attach.sh` is done with the key. The attach script needs the same state file.

## Flow: Send files from disk as attachments

**Entry:** `sh c3-attach.sh post <key> <thread> [--kind …] [--to …] [--reply-to …] [--body …] FILE…` / `sh c3-attach.sh open <key> --title … FILE…`

1. **Trigger** — the agent sends a file it should not read into context · `plugin/skills/c3/scripts/c3-attach.sh:cmd_send`
2. **Guard** — the key's state file must exist (save it with `c3-watch.sh` first), at least one file is given, every file is readable, and `open` requires `--title`. Any violation is exit 2 · `plugin/skills/c3/scripts/c3-attach.sh:state_file`
3. **Logic** — the script builds the JSON by hand: string fields are escaped by `awk`, each file is sent as `{"filename": <basename>, "base64": …}`, and the body defaults to `"See attached."` with kind `note` · `plugin/skills/c3/scripts/c3-attach.sh:build`, `plugin/skills/c3/scripts/c3-attach.sh:json_string`
4. **Persist / call** — the JSON is written to a `mktemp` file, removed on exit by a trap. It is then POSTed to `/v1/threads/<thread>/messages` (post) or `/v1/sessions/<code>/threads` (open), with the token passed on stdin · `plugin/skills/c3/scripts/c3-attach.sh:send`
5. **Notify** — server-side the resulting `message.posted` / `thread.opened` carries `attachments`, so the recipient's watcher line ends in `files <n>` · `lib/c3/watch.ex:files`
6. **Respond** — the script prints the server's JSON. An HTTP status of 400 or more prints `HTTP <status> <body>` to stderr and exits 1 · `plugin/skills/c3/scripts/c3-attach.sh:send`

**Touch this flow when:** the message or thread API body shape changes, or new message options (flags) are needed.
**Breaks when:**
- **The server limits are exceeded** (by default 5 MB per file, 10 MB per message, 50 MB per session, per `plugin/skills/c3/SKILL.md`). Those limits are enforced server-side; see `attachments`.
- **A `--to` with several recipients is passed.** `--to` is sent as a single JSON string, not a list.

## Flow: Download an attachment to disk

**Entry:** `sh c3-attach.sh get <key> <attachment-id> [OUT]`

1. **Trigger** — the agent saves an attachment instead of using `c3_get_attachment` (that tool is inline and capped at 1 MB) · `plugin/skills/c3/scripts/c3-attach.sh:cmd_get`
2. **Guard** — the id must be numeric, and the state file must exist · `plugin/skills/c3/scripts/c3-attach.sh:cmd_get`
3. **Persist / call** — `GET /v1/attachments/<id>` with curl `-o OUT`. `OUT` defaults to the id itself, in the current directory · `plugin/skills/c3/scripts/c3-attach.sh:cmd_get`
4. **Respond** — on success the script prints the path. On HTTP 400 or above it prints the error body (curl had already written it into `OUT`) to stderr, deletes `OUT`, and exits 1 · `plugin/skills/c3/scripts/c3-attach.sh:cmd_get`

**Touch this flow when:** the attachment download route or its auth changes.
**Breaks when:** `OUT` points into the repository. Downloads are data and belong outside it unless they really are part of the work (`plugin/skills/c3/SKILL.md`). An existing file at `OUT` is overwritten without asking.

## Shared state

- **The state file `$STATE_DIR/<code>-<name>`** is written only by `plugin/skills/c3/scripts/c3-watch.sh:write_state` and read by both scripts. It is the only place the token lives outside the transcript.
- **The event feed and its cursor (`seq`)** are owned by `event-feed`: `Events.wait_after` and the `/watch` route in `lib/c3_web/controllers/v1/event_controller.ex:watch`. This feature only filters that feed.
- **Agent identity (`name`, `label`, `number`)**, which `lib/c3/watch.ex:line` matches on, is owned by `sessions-and-agents`.
- **The request, claim and cancel semantics** behind the `request` / `answer` / `cancelled` / `claim_expired` lines are owned by `threads-and-requests`.
- **The `security`, `closing_soon` and `stop` sources** are owned by `join-security` and `session-lifecycle`.
- **Attachment storage and limits** are owned by `attachments`.
