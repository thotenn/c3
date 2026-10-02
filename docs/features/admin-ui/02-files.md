---
doc: features/admin-ui/02-files
repo: c3
kind: feature-files
anchored_to: e99b2ae68a77d78a2e21f0ef4b0fcfacc34b1f16
generated: 2026-10-02
---
# Admin UI — files

The admin UI has two layers. `lib/c3/admin.ex:C3.Admin` is a thin context: every admin read and action goes through it, and it mostly delegates to `C3.Sessions`, `C3.Threads`, `C3.Security` and `C3.Events`. The web layer is two LiveViews, one shared component module and two plain controllers. Login and logout use plain controllers, not LiveViews, because they write the session cookie. The attachment download is also a plain controller, because it streams a file. The part that surprises people is where the auth lives. The gate is not in any owned file. It is the `:admin` pipeline in `lib/c3_web/router.ex` (`C3Web.Plugs.AdminEnabled`, which returns a 404 while `C3_ADMIN_TOKEN` is unset), plus `lib/c3_web/admin_auth.ex` (`on_mount` and the `require_admin` plug). The owned files only hold the token checks, in `lib/c3/admin.ex:valid_token?` and `lib/c3/admin.ex:fingerprint`.

**Owned globs:** `lib/c3/admin.ex`, `lib/c3_web/live/admin/*.ex`, `lib/c3_web/controllers/admin_session_controller.ex`, `lib/c3_web/controllers/admin_session_html.ex`, `lib/c3_web/controllers/admin_session_html/new.html.heex`, `lib/c3_web/controllers/admin_attachment_controller.ex`

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/admin.ex` | `C3.Admin.list_sessions/0` | context | One query for every session (open, and closed ones still within retention) with agent and thread counters, built from `subquery` aggregates | adding a column or counter to the sessions list; changing the list's sort order (open first, then `last_activity_at`) |
| `lib/c3/admin.ex` | `C3.Admin.get_session/1` | context | Looks up a session by code after normalizing it the way a join does (`C3.Credentials.normalize_code`); returns `nil` for a malformed code | the admin URL should accept another code format |
| `lib/c3/admin.ex` | `C3.Admin.list_threads/1`, `C3.Admin.get_thread/2` | context | Threads with their derived state; one thread with its messages and `opened_by_agent` preloaded | showing more thread or message data in the detail page |
| `lib/c3/admin.ex` | `C3.Admin.close_session/1`, `finish_thread/1`, `unlock_joins/1`, `revoke_agent/1` | context | Admin actions, delegated to `Sessions` and `Threads` with `:admin` as the actor | adding an admin action, or changing who an action is recorded as |
| `lib/c3/admin.ex` | `C3.Admin.unban/1`, `C3.Admin.purge_session/1` | context | The two actions that emit no session event: they only call `Events.notify_admin` (`{:unbanned, ip}`, `{:purged, id}`) | a new action has no session to log to (a ban is per IP; a purged session has nowhere to hold an event) |
| `lib/c3/admin.ex` | `C3.Admin.enabled?/0`, `valid_token?/1`, `fingerprint/0`, `valid_login?/3` | context | The token checks. The cookie stores an HMAC fingerprint of the token, never the token itself, so rotating the token voids every login. The TTL is `admin_session_ttl` | changing login expiry; changing what the cookie stores |

## LiveViews

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/live/admin/session_live.ex` | `C3Web.Admin.SessionLive` | liveview | One session's agents, threads, selected thread (`:thread` action) and event log, with the close, unlock, revoke, finish, purge and "load older" buttons | adding a button or panel to the session page; changing which event types refresh which panel (`@agent_types`, `@thread_types`) |
| `lib/c3_web/live/admin/session_live.ex` | `fetch_events/1`, `schedule_reload/1`, `reload_session/1` | liveview | Pulls events past `last_seq` in pages of `@page`, marks panels stale, and reloads them once per `@debounce_ms`. If the session row is gone, it navigates back to `/admin` | the live updates lag or flood; supporting a new event type |
| `lib/c3_web/live/admin/sessions_live.ex` | `C3Web.Admin.SessionsLive` | liveview | Front page: the session list, stats and active bans, with the unban action. Every broadcast only schedules a reload (`@debounce_ms` 1 s), and `@tick_ms` reloads anyway | changing the front page; showing bans differently |
| `lib/c3_web/live/admin/components.ex` | `C3Web.Admin.Components` (`session_status`, `thread_status`, `agent_status`, `time`, `event_summary`, `format_bytes`) | component | Badges and the one-line, human-readable rendering of each event type | adding an event type (it needs a clause in `event_summary`); restyling a status badge |

Both LiveViews subscribe with `Events.subscribe_admin()` before their first read. `SessionLive` ignores any `{:c3_events, id, seq}` whose `seq` is not past `last_seq`, or whose session is not the one on screen.

## Controllers

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/controllers/admin_session_controller.ex` | `C3Web.AdminSessionController` (`new`, `create`, `delete`) | controller | Login form and logout. A wrong token returns 401 and logs a warning. Logins are limited to `@login_limit` (10) per minute per IP, through `RateLimiter.hit({:admin_login, ip}, …)`, on top of the IP limit of the `:admin` pipeline | changing the login limits or messages |
| `lib/c3_web/controllers/admin_session_html.ex` | `C3Web.AdminSessionHTML` | component | `embed_templates "admin_session_html/*"` | adding a login-related template |
| `lib/c3_web/controllers/admin_session_html/new.html.heex` | `new` | page | The token login form | restyling the login page |
| `lib/c3_web/controllers/admin_attachment_controller.ex` | `C3Web.AdminAttachmentController.show/2` | controller | Admin download of an attachment, scoped to the session in the URL (`Attachments.fetch_in`). Anything not found returns a plain-text 404. It reuses the agent's `send_attachment/2`, so it sends the same headers | changing download headers (change them in the shared function, not here) |

The routes are in `lib/c3_web/router.ex`, `scope "/admin"`. The LiveViews sit inside `live_session :admin`, with `on_mount: {C3Web.AdminAuth, :require_admin}`. The controllers use `plug :require_admin` themselves (the attachment controller does; login and logout must not).

## Tests

| Path | Covers |
|---|---|
| `test/c3/admin_test.exs` | access and token checks, `list_sessions/0` counters, close, revoke, unban, purge, and the "F8 actions" (finish and unlock) |
| `test/c3_web/live/admin_live_test.exs` | login flow, the sessions list page, the session detail page |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3_web/admin_auth.ex` | _(undetermined)_ (auth: the `on_mount` hook and the `require_admin` plug) |
| `lib/c3_web/plugs/admin_enabled.ex`, `lib/c3_web/plugs/rate_limit.ex`, `lib/c3_web/plugs/real_ip.ex` | [`join-security`](../join-security/) / the request pipeline docs |
| `lib/c3_web/router.ex` | the request pipeline docs |
| `C3.Events` topics and `list_after` / `list_recent` | [`event-feed`](../event-feed/) |
| `C3.Sessions.close_session!`, `revoke`, `unlock_joins` | [`session-lifecycle`](../session-lifecycle/), [`sessions-and-agents`](../sessions-and-agents/) |
| `C3.Threads.admin_finish`, thread states | [`threads-and-requests`](../threads-and-requests/) |
| `C3.Attachments`, `C3Web.V1.AttachmentController.send_attachment/2` | [`attachments`](../attachments/) |
| `C3.Security` bans | [`join-security`](../join-security/) |
