---
doc: features/admin-ui/00-INDEX
repo: c3
kind: feature-index
tier: B
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Admin UI

A browser console for the person who runs the C3 server. It lists every session, open or recently closed. For each session it shows the agents, the threads, the messages and the live event log. It also shows the server's counters and the IP addresses currently banned. From the console the operator can close a session, purge a closed one, revoke one agent, finish a thread, let new agents join a locked session again, lift an IP ban, and download an attachment. There are no admin users. Anyone who has the admin token can log in, and if no token is configured the admin pages do not exist.

## Does this ticket belong here?

**Yes if it mentions:** the admin page or dashboard, the admin login or logout, the admin token, a session list or a session detail page that is stale or not live, the admin killing a session or kicking an agent, unbanning an IP from the UI, purging a session by hand, the admin downloading an attachment, the stats or counters on the front page, "load older events".
**UI labels:** `Admin`, `Admin token`, `Invalid admin token.`, `Too many attempts. Try again in … s.`, `Sessions`, `IP bans in force`, `Open sessions`, `Active agents`, `Bans in force`, `Attachments`, `Sessions created`, `Sessions closed`, `Failed joins`, `Bans issued`, `Long-polls · …`, `Unban`, `Unlock joins`, `Close session`, `Purge now`, `Revoke`, `Finish thread`, `Load older events`, `Log out`; env var `C3_ADMIN_TOKEN`.
**Routes:** `/admin`, `/admin/login`, `/admin/logout`, `/admin/sessions/:code`, `/admin/sessions/:code/threads/:number`, `/admin/sessions/:code/attachments/:id`
**No — go elsewhere if:**
- An agent closes, leaves or unlocks through the API or MCP → [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md)
- Wrong security number, bans being issued, the join lock → [`join-security`](../join-security/00-INDEX.md)
- Automatic expiry or retention purge → [`session-lifecycle`](../session-lifecycle/00-INDEX.md)
- How the counter values are computed → [`metrics`](../metrics/00-INDEX.md)
- An event an agent's watcher receives → [`event-feed`](../event-feed/00-INDEX.md)

## Entry points

| Route | Page component | Module root |
|---|---|---|
| `GET /admin/login`, `POST /admin/login` | `lib/c3_web/controllers/admin_session_controller.ex:new` / `create`, template `lib/c3_web/controllers/admin_session_html/new.html.heex` | `lib/c3/admin.ex` |
| `DELETE /admin/logout` | `lib/c3_web/controllers/admin_session_controller.ex:delete` | `lib/c3/admin.ex` |
| `/admin` | `lib/c3_web/live/admin/sessions_live.ex:C3Web.Admin.SessionsLive` | `lib/c3/admin.ex` |
| `/admin/sessions/:code` and `/admin/sessions/:code/threads/:number` | `lib/c3_web/live/admin/session_live.ex:C3Web.Admin.SessionLive` (`:show` / `:thread`) | `lib/c3/admin.ex` |
| `GET /admin/sessions/:code/attachments/:id` | `lib/c3_web/controllers/admin_attachment_controller.ex:show` | `lib/c3/admin.ex` |

Shared badges and formatters (`session_status`, `thread_status`, `agent_status`, `time`, `format_bytes`, `event_summary`) live in `lib/c3_web/live/admin/components.ex`.

## Traps worth knowing first

- **The login cookie stores a fingerprint, not the token.** `lib/c3/admin.ex:fingerprint` is an HMAC of the token. Changing `C3_ADMIN_TOKEN` logs out every browser. `lib/c3/admin.ex:valid_login?` also expires a login after `admin_session_ttl`, and it rejects a login time that is in the future.
- **Login has two rate limits.** `lib/c3_web/controllers/admin_session_controller.ex:@login_limit` allows 10 attempts per minute per IP, and the per-IP limit of the whole `/admin` scope applies on top of that. The submitted token is trimmed before it is compared.
- **Every admin action calls the domain function an agent would trigger**, so each one leaves the same events as its automatic version: `lib/c3/admin.ex:close_session` (reason `admin`), `lib/c3/admin.ex:revoke_agent`, `lib/c3/admin.ex:unlock_joins`, `lib/c3/admin.ex:finish_thread`. Do not add admin-only side paths to these.
- **Two actions produce no session event.** `lib/c3/admin.ex:unban` and `lib/c3/admin.ex:purge_session` only broadcast `{:c3_admin, …}`. An unban is per IP, and a purged session has nowhere left to hold an event. If you add another action of this kind, both LiveViews must handle its message: see `handle_info({:c3_admin, …})` in `lib/c3_web/live/admin/session_live.ex:handle_info` and `lib/c3_web/live/admin/sessions_live.ex:handle_info`.
- **Live updates are debounced, not one query per event.** `lib/c3_web/live/admin/sessions_live.ex:@debounce_ms` (1 s) marks the whole page stale. `lib/c3_web/live/admin/session_live.ex` appends events to the log and decides what to reload from the event type, using `@agent_types` and `@thread_types`. A new event type that changes agents or threads must be added to those lists, or the page goes stale. Both pages also reload every `@tick_ms` (30 s), for values that change without an event (`last_seen_at`, ban expiries).
- **The session list orders by `status` descending, then by last activity** (`lib/c3/admin.ex:list_sessions`). The status sort uses the raw stored value. Its open/closed counts use SQL `CASE` fragments; keep them portable to Postgres.
- **A session code in a URL is normalized like a join code** (`lib/c3/admin.ex:get_session`). If it does not normalize, or the attachment is in another session, the attachment download returns a plain `404 Not found` (`lib/c3_web/controllers/admin_attachment_controller.ex:show`).

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) | What closing a session or revoking an agent actually does (token revocation, `stop` to watchers) |
| [`threads-and-requests`](../threads-and-requests/00-INDEX.md) | Thread state derivation and what "finish" cancels |
| [`join-security`](../join-security/00-INDEX.md) | How bans and join locks are created; the data behind `Unban` / `Unlock joins` |
| [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | Retention and the purge itself (`Purge now` only triggers it) |
| [`attachments`](../attachments/00-INDEX.md) | Attachment storage and the download headers (reused via `send_attachment`) |
| [`metrics`](../metrics/00-INDEX.md) | The counters and gauges shown on `/admin` |
| [`event-feed`](../event-feed/00-INDEX.md) | Event types, `seq`, and the `admin` PubSub topic announcements |
| [`health-and-home`](../health-and-home/00-INDEX.md) | The public home page |

The auth plug, `C3Web.AdminAuth`, and the `AdminEnabled` plug are outside this feature's scope. This document does not cover them. Their behaviour is _(undetermined)_ here.

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | how a login, an action, or an incoming event reaches the screen |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |

## Related

- Features: [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md), [`join-security`](../join-security/00-INDEX.md), [`session-lifecycle`](../session-lifecycle/00-INDEX.md), [`metrics`](../metrics/00-INDEX.md), [`event-feed`](../event-feed/00-INDEX.md), [`attachments`](../attachments/00-INDEX.md)
