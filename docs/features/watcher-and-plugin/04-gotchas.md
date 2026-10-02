---
doc: features/watcher-and-plugin/04-gotchas
repo: c3
kind: feature-gotchas
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Watcher and Claude Code Plugin — gotchas

## Non-obvious behaviour

### The server decides relevance, not the script
`c3-watch.sh` never parses JSON. It prints every line that `/watch` returns, except the `cursor` line and blank lines. The server decides which lines exist: `lib/c3/watch.ex:line` is called per event from `lib/c3_web/controllers/v1/event_controller.ex:watch_after`. Events that do not concern the agent still advance the cursor, and the request stays held. · `plugin/skills/c3/scripts/c3-watch.sh:cmd_wait`
**Costs you:** if you add a wake-up condition in the script, it will never fire, because the server has already filtered the event out. Add a `relevant/3` clause in `lib/c3/watch.ex` instead.

### What the agent did itself never wakes it
Every request, answer and cancellation clause checks that the actor is not `me.name`. A request to `any` also leaves out its author (`lib/c3/watch.ex:for_me?`). · `lib/c3/watch.ex:relevant`
**Costs you:** a test where an agent asks itself something expects a line and gets `nil`.

### A thread opened to several targets produces one line per agent
For `thread.opened`, the clause zips `to` with `requests` and keeps only the **first** target that matches `me`. Say an agent matches both by name and through `any`: it gets one `request` line, carrying the request ref of the first match. · `lib/c3/watch.ex:relevant`
**Costs you:** you might expect one line per request the agent can take. The other requests appear only through `c3_inbox`.

### `joined` only reaches AG1; `security` and `closing_soon` reach everyone
`agent_joined` matches only `%{number: 1}`. Join failures, the join lock and the closing warning have no recipient check: every agent's watcher wakes on them. · `lib/c3/watch.ex:relevant`
**Costs you:** one brute-force attempt on the join wakes every agent in the session.

### Only some line kinds carry a title
The quoted thread title is added only for `request`, `answer` and `cancelled`. Before it goes out, control characters and whitespace runs are collapsed, `"` becomes `'`, and the result is cut to `@title_max` (80). It is always the last field. · `lib/c3/watch.ex:title`
**Costs you:** a parser that splits on spaces and expects a fixed number of fields breaks. `files <n>` is optional and sits before the title (`lib/c3/watch.ex:files`).

### Cancellation relevance depends on whether the request was claimed
For a claimed request, only the holder is woken. For an unclaimed one, every agent the request was addressed to is woken, `any` included, author excluded. · `lib/c3/watch.ex:relevant` (`:request_cancelled`)
**Costs you:** an agent that was addressed but never claimed the request can still get a `cancelled` line.

### `save` skips the backlog, unless the server cannot be reached
A fresh `save` sets the cursor to the session's current end by paging `/watch?wait=0` (`plugin/skills/c3/scripts/c3-watch.sh:current_end`). Anything that was already waiting has to be read from the inbox; `plugin/skills/c3/SKILL.md` documents this. If the server cannot be reached, `current_end` returns **0**, and the first `wait` then replays every relevant event since the session started. · `plugin/skills/c3/scripts/c3-watch.sh:cmd_save`
**Costs you:** after a `save` during a network blip, old requests and stops show up as if they were new.

### `save` with the same token keeps the cursor; a new token resets it
The key is `<code>-<name>`. Re-saving with the same token reuses the stored `after`. A different token (for example after rejoining) starts again from the current end. · `plugin/skills/c3/scripts/c3-watch.sh:cmd_save`
**Costs you:** if you expect a re-save to move the cursor to "now", it does not.

### The exit status is always 0; the lines say what happened
News, `idle` after `C3_WATCH_MAX_SECONDS` (default 6000) and `stop` all exit 0. Only usage errors exit 2. Every exit except a stop prints a `relaunch:` line. HTTP 401, 403, 404 and 410 become `stop http_<status> <body…>`, with the body cut to 200 characters. · `plugin/skills/c3/scripts/c3-watch.sh:cmd_wait`
**Costs you:** code that tests `$?` to detect a stopped session never sees one. A new HTTP stop condition must also be added to this `case`, or the script keeps retrying it with backoff.

### `C3_URL` overrides the URL for the connection, not in the file
`wait` connects to `C3_URL` when it is set, but when it saves the cursor it rewrites the state file with the URL read back from the file (`write_state … "$(get url "$file")"`). · `plugin/skills/c3/scripts/c3-watch.sh:cmd_wait`
**Costs you:** the override does not persist. That is intended: the override is temporary.

### Network errors never end `wait`
A curl failure, or any status that is not 200, an auth status or 429, is retried with exponential backoff (starting at `C3_WATCH_RETRY`, capped at 60 s). A 429 sleeps a flat 30 s and does not touch the backoff. The loop ends only on news, a stop, or `MAX_SECONDS`. · `plugin/skills/c3/scripts/c3-watch.sh:cmd_wait`
**Costs you:** when the server is down the watcher just goes quiet, and ends with an `idle` line.

### `usage` prints fixed comment lines
`usage()` prints lines `7,10p` of `c3-watch.sh` and lines `7,9p` of `c3-attach.sh`. · `plugin/skills/c3/scripts/c3-watch.sh:usage`, `plugin/skills/c3/scripts/c3-attach.sh:usage`
**Costs you:** adding or removing a line in the header comment silently changes what the help prints.

### `c3-attach.sh` depends on the watcher's state
`c3-attach.sh` has no `save` of its own. It reads url, code and token from the file that `c3-watch.sh save` wrote, and exits 2 if that file is missing. · `plugin/skills/c3/scripts/c3-attach.sh:state_file`
**Costs you:** after `forget`, attachments stop working too.

### `c3-attach.sh` quirks
- `open` silently ignores `--kind` and `--reply-to`. `post` defaults to `kind` `note` and to the body `See attached.` · `plugin/skills/c3/scripts/c3-attach.sh:cmd_send`
- Only the last path segment of each file is sent as its name, so two `log.txt` files from different directories arrive with the same name. · `plugin/skills/c3/scripts/c3-attach.sh:build`
- Each file is base64-encoded whole into a temp file before the POST. Size limits are enforced by the server ([attachments](../attachments/)), and only after the upload.
- `get` with no `OUT` writes a file named after the attachment id in the current directory, not the original filename. On an HTTP error it deletes that file and exits 1. · `plugin/skills/c3/scripts/c3-attach.sh:cmd_get`
- `json_string` drops control characters other than tab, CR and LF; they are not escaped. · `plugin/skills/c3/scripts/c3-attach.sh:json_string`

## Known workarounds in the code

- **The token goes to curl on stdin** (`-K -` with a `header = …` config line). It is never put in argv, which other users can read in `ps`. Both scripts do this (`plugin/skills/c3/scripts/c3-watch.sh:poll`, `plugin/skills/c3/scripts/c3-attach.sh:send`), and `save` reads the token from stdin for the same reason.
- **The state is written to a temp file, then `mv`-ed, under `umask 077`.** The cursor is saved after every poll that moves it, so a write cut off mid-way cannot leave a half-written file, and the file holds a token. `list` skips `*.tmp.*` leftovers. · `plugin/skills/c3/scripts/c3-watch.sh:write_state`, `plugin/skills/c3/scripts/c3-watch.sh:cmd_list`
- **curl's `--max-time` is `wait + 15`.** This leaves the server time to answer after holding the long-poll for the full `wait`. A tighter timeout turns every quiet poll into a network error and a backoff. · `plugin/skills/c3/scripts/c3-watch.sh:poll`
- **The key is rejected when it is empty or contains `/` or `..`.** The key becomes a file path under `STATE_DIR`. · `plugin/skills/c3/scripts/c3-watch.sh:state_file`
- **`[ "$status" -ge 400 ] 2>/dev/null`.** This tolerates a status that is not a number, such as an empty one when curl wrote no `-w` output. · `plugin/skills/c3/scripts/c3-attach.sh:send`

## Coverage

| Test | Pins |
|---|---|
| `test/c3_web/controllers/v1/watch_test.exs` | Who gets woken: by name, by label, `any` excluding the author, multi-target threads as one line, answers, cancellations, `joined` for AG1 only, `security` for everyone, stop and 410, title sanitising |
| `test/c3/watch_script_test.exs` | The real script: exits on a request for its agent, survives an unreachable server and resumes from its cursor, a stop has no relaunch, `idle` plus relaunch, `save` skips the backlog, `save` keeps the cursor for the same token, `list` never shows tokens |
| `test/c3/admin_test.exs` | `stop … by admin`, `revoked`, and admin cancellations as seen by `lib/c3/watch.ex:line` |
| `test/c3/attach_script_test.exs` | `c3-attach.sh` end to end _(cases undetermined)_ |

Not covered and would break silently:
- the `current_end` = 0 fallback in `save`
- the 429 branch
- `C3_URL` not persisting
- `closing_soon` and `claim_expired` lines through the script

## Prior tickets

| Ticket | What it changed | Watch out |
|---|---|---|
| `C3-1` | F6 shipped the plugin, the skill and the watcher. A follow-up fix made the watcher start at the session's end, added the `joined` line, and made a stop exit 0 | The backlog belongs to the inbox, not to the watcher: do not make `save` start at 0 again. A non-zero exit on stop was removed on purpose |
