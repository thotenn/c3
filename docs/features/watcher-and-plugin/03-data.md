---
doc: features/watcher-and-plugin/03-data
repo: c3
kind: feature-data
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Watcher and Claude Code Plugin — data

**Entry module:** `lib/c3/watch.ex:C3.Watch` · **Transport:** REST (plain-text long-poll + JSON) called by shell clients `plugin/skills/c3/scripts/c3-watch.sh` and `plugin/skills/c3/scripts/c3-attach.sh`

## Endpoints

The scripts are clients of the endpoints below. The handlers belong to sibling features: `/watch` belongs to [event-feed](../event-feed/), threads and messages to [threads-and-requests](../threads-and-requests/), and attachments to [attachments](../attachments/). This feature owns only the filter `lib/c3/watch.ex:line`, which the `/watch` handler applies to each event (`Watch.line` in `lib/c3_web/controllers/v1/event_controller.ex`).

| Operation | Method / name | Caller | Input | Output | Side effects |
|---|---|---|---|---|---|
| wait for news | `GET <url>/v1/sessions/<code>/watch?after=<seq>&wait=<s>` | `plugin/skills/c3/scripts/c3-watch.sh:poll` (from `cmd_wait`) | Bearer token, sent to curl on stdin via `-K -` | text: one `cursor <seq>` line plus one line per relevant event, built by `lib/c3/watch.ex:line` | the script writes the new `after` to its state file |
| find the session end | same endpoint with `wait=0`, paged | `plugin/skills/c3/scripts/c3-watch.sh:current_end` | same | same | runs on the first `save` only. It returns `0` if the server is unreachable, so the watcher then replays from the beginning |
| post with files | `POST <url>/v1/threads/<thread>/messages` | `plugin/skills/c3/scripts/c3-attach.sh:cmd_send` (`post`) | JSON body built by `plugin/skills/c3/scripts/c3-attach.sh:build`: `body`, `kind` (default `note`), `to`, `reply_to`, and `attachments[{filename,base64}]` | the server's JSON, printed to stdout | creates a message |
| open with files | `POST <url>/v1/sessions/<code>/threads` | `plugin/skills/c3/scripts/c3-attach.sh:cmd_send` (`open`) | `body`, `title` (required), `to`, `attachments` | server JSON | creates a thread with a first request |
| download | `GET <url>/v1/attachments/<id>` | `plugin/skills/c3/scripts/c3-attach.sh:cmd_get` | numeric id | file written to `OUT` (default: the id, in the cwd); the script prints the path | on HTTP ≥ 400 the file is deleted and the error body goes to stderr |

### Watch line vocabulary (`lib/c3/watch.ex:relevant`)

Line format: `<kind> <seq> <facts…>`. The `request` and `answer` kinds append `files <n>` (`lib/c3/watch.ex:files`). `request`, `answer` and `cancelled` lines end with the quoted thread title. The title is the only free text: control characters and whitespace collapse to single spaces, `"` becomes `'`, and the title is cut to 80 characters (`lib/c3/watch.ex:title`, `@title_max`).

| Event type | Becomes | Condition (non-obvious part) |
|---|---|---|
| `:thread_opened` | `request` | **One line only**, for the first `to`/`requests` pair that targets me. A thread with several targets never produces two lines |
| `:message_posted` kind `request` | `request` | `for_me?`: my name, `label:<my label>`, or `any`. `any` excludes the author |
| `:message_posted` kind `response` | `answer` | `me.name in resolved_for`. Responses where I'm not in `resolved_for` produce no line |
| `:request_cancelled` | `cancelled` | if claimed, the holder must be me; if unclaimed, the request must be addressed to me |
| `:request_claim_expired` | `claim_expired` | only the claim holder gets it |
| `:agent_joined` | `joined` | **only `AG1`** (`%{number: 1}`) gets it |
| `:security_join_failed`, `:session_joins_locked` | `security` | every agent gets it |
| `:session_closing_soon` | `closing_soon` | every agent gets it |
| `:session_closed`, `:agent_left` (self), `:agent_revoked` (self) | `stop` | — |

Events the agent caused itself never produce a line: the `by != me.name` guards cover this. Security events have no such guard.

## Cache, events and invalidation

- `lib/c3/watch.ex:line` reads two inputs: the event payload keys that the producers write (`opened_by`, `to`, `requests`, `author`, `resolved_for`, `resolved`, `claimed_by`, `cancelled_by`, `attachments`, …) and the preloaded `event.thread`. **If a producer renames a payload key, the watcher stops waking agents without raising an error.** The `relevant/3` catch-all returns `nil`. The producers are in [threads-and-requests](../threads-and-requests/), [sessions-and-agents](../sessions-and-agents/), [join-security](../join-security/) and [session-lifecycle](../session-lifecycle/).
- `lib/c3/watch.ex:title` requires `event.thread` to be loaded for `request`/`answer`/`cancelled`. Without it, the line has no title.
- The cursor advances past events that don't concern the agent, and those events produce no line. A missed wake-up therefore cannot be recovered by re-polling: the agent has to read `c3_inbox` (`plugin/skills/c3/SKILL.md`).
- A new state from `save` puts the cursor at the session's current end. Anything that arrived earlier must be read from the inbox right after saving (header of `plugin/skills/c3/scripts/c3-watch.sh`).

## Scoping

- Server side: the Bearer token identifies the agent (`%C3.Sessions.Agent{}`). `line/2` filters the session's feed for that agent. Session and token validation belong to [event-feed](../event-feed/) and [sessions-and-agents](../sessions-and-agents/).
- Client side: the state key is `<code>-<name>` (`cmd_save`), so several agents on one machine do not collide. `state_file` rejects keys that are empty or contain `/` or `..` (exit 2).
- Missing scope: `wait` without a state file exits 2. HTTP `401/403/404/410` becomes `stop http_<status> <body…>` with exit 0. These responses are not retried, so a revoked token or a closed session ends the watcher. `C3_URL` overrides the saved URL for both scripts.

## Local state

| What | Where | Lifetime |
|---|---|---|
| state file: `url`, `code`, `name`, `token`, `after` | `$C3_STATE_DIR`, default `${XDG_STATE_HOME:-$HOME/.local/state}/c3/<key>`, mode 600 (`plugin/skills/c3/scripts/c3-watch.sh:write_state`, written atomically through a `.tmp.$$` file and `mv`) | survives restarts. `after` is saved after every poll that moves the cursor. Removed only by `forget` |
| re-`save` with the same token | `cmd_save` | keeps the old `after`. A different token resets `after` to the session's current end |
| `c3-attach.sh` request body | a `mktemp` file under `$TMPDIR` | deleted by an EXIT trap. File contents are piped through `base64` and never go through argv or the agent |
| watcher loop timers | `C3_WATCH_MAX_SECONDS` (6000), `C3_WATCH_POLL` (30), `C3_WATCH_RETRY` (2) | network errors and unexpected statuses back off exponentially up to 60 s; `429` sleeps 30 s. On timeout the watcher prints `idle` |

`c3-attach.sh` has no state of its own: it reads the file that `c3-watch.sh save` wrote, so `save` has to run before `post`, `open` or `get` will work. `lib/c3/watch.ex:C3.Watch` holds no state.

All exits from `wait` return 0, except usage errors (exit 2). Every exit other than `stop` ends with a `relaunch: sh "<script>" wait <key>` line (`plugin/skills/c3/scripts/c3-watch.sh:relaunch`).
