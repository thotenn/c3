---
doc: features/watcher-and-plugin/00-INDEX
repo: c3
kind: feature-index
tier: A
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Watcher and Claude Code Plugin

An agent that has joined a C3 session can't sit on a loop calling tools. It still needs to wake up when another agent asks it for something, answers it, cancels work it is doing, joins the session, or when the session is about to end. The watcher handles this. It runs in the background, waits quietly, and exits with a short line for each thing that concerns this agent. Claude Code reads that exit and wakes the agent. The plugin's skill tells the agent how to open or join a session, save its state, run the watcher and relaunch it each time, and send or download files without putting their content into the conversation.

## Does this ticket belong here?

**Yes if it mentions:** the agent not waking up; the watcher waking for its own messages, or for messages meant for someone else; the same event reported twice, or one that was missed after a restart or reconnect; the watcher exiting too early, never exiting, or not printing its relaunch line; the `joined` notice when a second agent arrives; the wording of the wake-up lines; thread titles in a wake-up line that break the format; the local state file or where it lives; the watcher surviving network cuts or rate limiting; Windows / Git Bash / macOS compatibility of the scripts; sending a file from disk or downloading an attachment from the command line; the skill's instructions to the agent.
**UI labels:** `c3-watch.sh save | wait | forget | list`, `c3-attach.sh post | open | get`, `--kind`, `--to`, `--reply-to`, `--title`, `--body -`, `C3_STATE_DIR`, `C3_URL`, `C3_WATCH_MAX_SECONDS`, `C3_WATCH_POLL`, `C3_WATCH_RETRY`. Line kinds: `request`, `answer`, `cancelled`, `claim_expired`, `joined`, `security`, `closing_soon`, `stop`, `idle`, `relaunch:`. Line form: `c3 <code> <name>`.
**Routes:** `GET /v1/sessions/:code/watch` (consumed by `c3-watch.sh`); `POST /v1/sessions/:code/threads`, `POST /v1/threads/:thread/messages`, `GET /v1/attachments/:id` (consumed by `c3-attach.sh`)
**No — go elsewhere if:**
- It is about how the long-poll holds the request, the `after`/`wait` semantics, or the generic event feed (`c3_events`). Go to [`event-feed`](../event-feed/00-INDEX.md).
- It is about attachment limits, storage, content types or the `c3_get_attachment` tool. Go to [`attachments`](../attachments/00-INDEX.md).
- It is about the `c3_*` MCP tools themselves. Go to [`mcp-server`](../mcp-server/00-INDEX.md).
- It is about why a session closed or when `closing_soon` fires. Go to [`session-lifecycle`](../session-lifecycle/00-INDEX.md).
- It is about join bans and locks. Go to [`join-security`](../join-security/00-INDEX.md).

## Entry points

| Route / command | Handler | Module root |
|---|---|---|
| `GET /v1/sessions/:code/watch` | `lib/c3_web/controllers/v1/event_controller.ex:watch` filters every event through `lib/c3/watch.ex:line` | `lib/c3/watch.ex` |
| `sh c3-watch.sh save <url> <code> <name>` (token on stdin) | `plugin/skills/c3/scripts/c3-watch.sh:cmd_save` | `plugin/skills/c3/scripts/` |
| `sh c3-watch.sh wait <key>` (Bash `run_in_background`) | `plugin/skills/c3/scripts/c3-watch.sh:cmd_wait` | `plugin/skills/c3/scripts/` |
| `sh c3-attach.sh post / open / get <key> …` | `plugin/skills/c3/scripts/c3-attach.sh:cmd_send`, `plugin/skills/c3/scripts/c3-attach.sh:cmd_get` | `plugin/skills/c3/scripts/` |
| Agent-facing contract | `plugin/skills/c3/SKILL.md` | `plugin/skills/c3/` |

## Traps and asymmetries

| Where | What you could not guess |
|---|---|
| `lib/c3/watch.ex:line` | The server decides relevance; the script never does. The script has only `sh` and `curl`, so it would otherwise have to parse JSON that contains free text. This is why the moduledoc of `lib/c3/watch.ex` puts the logic on the server. A new kind of wake-up is a new `relevant/3` clause, not a change to the script. |
| `lib/c3/watch.ex:relevant` | Each `relevant/3` clause for another agent's action is guarded with `by != me.name`. An agent's own actions never wake it. The exceptions are `agent_left` and `agent_revoked` for itself, because both map to `stop`. |
| `lib/c3/watch.ex:relevant` (`:thread_opened`) | A thread opened to several targets produces **one** line, for the first target that matches `me`, even when the agent matches several targets (for example by name and by `any`). |
| `lib/c3/watch.ex:for_me?` | `any` excludes the author. `label:` matches `me.label`. Any other target is compared with the agent name. |
| `lib/c3/watch.ex:relevant` (`:request_cancelled`) | A claimed request notifies only its holder. An unclaimed one notifies whoever it was addressed to. |
| `lib/c3/watch.ex:relevant` (`:agent_joined`) | `joined` goes only to agent number 1 (`%{number: 1}`), the session's creator. |
| `lib/c3/watch.ex:relevant` (security, `closing_soon`, `session_closed`) | These go to every agent, with no author guard. |
| `lib/c3/watch.ex:title` | The title is the only free text in a line, and only `request` / `answer` / `cancelled` lines carry it. It always goes last. Control characters and whitespace runs collapse to one space, `"` becomes `'`, and the title is cut to `@title_max` (80). Anything that parses a line depends on this order. `files <n>` comes just before the title. |
| `plugin/skills/c3/scripts/c3-watch.sh:cmd_save` | The cursor of a new save starts at the session's **current end**. `plugin/skills/c3/scripts/c3-watch.sh:current_end` gets it by paging `/watch` with `wait=0` until the cursor stops moving. Because of that, the skill requires reading `c3_inbox` right **after** `save` (step 3 of "Starting" in `plugin/skills/c3/SKILL.md`). A second save with the same token keeps the saved cursor. |
| `plugin/skills/c3/scripts/c3-watch.sh:cmd_wait` | The cursor is saved to the state file after every poll that moved it, so a restart loses nothing and reports nothing twice. The script ignores everything in the body except the `cursor` line and the news lines. |
| `plugin/skills/c3/scripts/c3-watch.sh:cmd_wait` | Exit code is always 0. Exit 2 means a usage error. The output lines carry the meaning. A `stop` line, or an HTTP `401 / 403 / 404 / 410`, ends without a `relaunch:` line. Every other exit, `idle` included, prints one. The agent must relaunch the watcher every time, or nothing wakes it again. |
| `plugin/skills/c3/scripts/c3-watch.sh:cmd_wait` | Network errors and unexpected statuses back off exponentially from `C3_WATCH_RETRY` up to 60 s. A `429` sleeps a fixed 30 s. The whole run ends with `idle` after `C3_WATCH_MAX_SECONDS` (default 6000). That default is below the 7200000 ms Bash timeout the skill asks for. |
| `plugin/skills/c3/scripts/c3-watch.sh:poll` and `plugin/skills/c3/scripts/c3-attach.sh:send` | The token reaches curl through a `-K -` config on stdin, never on the command line, so it never shows up in process listings. Keep it that way. |
| `plugin/skills/c3/scripts/c3-watch.sh:write_state` | The state file is written atomically (temp file + `mv`) under `umask 077`. `c3-watch.sh:cmd_list` skips `*.tmp.*` files and never prints tokens. |
| `plugin/skills/c3/scripts/c3-watch.sh:state_file` | The key is `<code>-<name>`. A key that contains `/` or `..` is rejected. `plugin/skills/c3/scripts/c3-attach.sh:state_file` reuses the same state and refuses to run if the watcher has not saved it. |
| `plugin/skills/c3/scripts/c3-watch.sh:usage` and `plugin/skills/c3/scripts/c3-attach.sh:usage` | The usage text is printed with `sed -n '7,10p'` / `'7,9p'` of the script's own header. Editing the header comment shifts or breaks the help text. |
| `plugin/skills/c3/scripts/c3-attach.sh:json_string` | JSON is built by hand with `awk`. Tabs, CRs and newlines are escaped, and any other control character is **dropped** silently. Each file is sent as base64 under its last path segment. The default `--kind` is `note`, and the default body is `"See attached."`. |
| `plugin/skills/c3/scripts/c3-attach.sh:cmd_get` | On an HTTP error, the partial output file is deleted and the error body goes to stderr with exit 1. The attachment id must be numeric. |
| `C3_URL` | Overrides the saved `url` in both scripts (`cmd_wait`, `cmd_send`, `cmd_get`). It is not written back to state. |
| `plugin/` versioning | Any change under `plugin/` must bump `plugin/.claude-plugin/plugin.json`, or `claude plugin update` skips it. The repo's `CLAUDE.md` states this rule. |

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`event-feed`](../event-feed/00-INDEX.md) | How `/watch` holds the request, the `cursor` line, event `seq` ordering, the `c3_events` tool |
| [`threads-and-requests`](../threads-and-requests/00-INDEX.md) | Which payload fields (`resolved_for`, `claimed_by`, `requests`) an event carries, and how claims expire |
| [`attachments`](../attachments/00-INDEX.md) | The endpoints `c3-attach.sh` calls, the size limits, how files are stored and served |
| [`mcp-server`](../mcp-server/00-INDEX.md) | The `c3_*` tools the skill tells the agent to use |
| [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | When `closing_soon` / `session_closed` are emitted, and which actions count as activity |
| [`join-security`](../join-security/00-INDEX.md) | Bans, the join lock, and secret rotation that produce `security` lines |
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) | Tokens, agent names and numbers, labels, leave / revoke |

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | save → inbox → wait → wake → relaunch, and how the cursor moves |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |

## Related

- Features: [`event-feed`](../event-feed/00-INDEX.md), [`attachments`](../attachments/00-INDEX.md), [`mcp-server`](../mcp-server/00-INDEX.md), [`session-lifecycle`](../session-lifecycle/00-INDEX.md)
