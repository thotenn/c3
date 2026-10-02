---
doc: features/admin-ui/01-flows
repo: c3
kind: feature-flows
anchored_to: e99b2ae
generated: 2026-10-02
---
# Admin UI — flows

The admin UI has seven flows. Logging in is a plain controller flow that writes a cookie. The two LiveViews are read-only and stay current from the `admin` PubSub topic: the sessions list and the per-session page. The admin actions each delegate to one domain function in `lib/c3/admin.ex`, so each leaves the same events as its non-admin version. Downloading an attachment is a plain controller flow. Every route sits behind `C3Web.Plugs.AdminEnabled`, which makes the whole `/admin` scope a 404 while `C3_ADMIN_TOKEN` is unset. There are no admin users: whoever holds that token is the admin.

## Flow: log in with the admin token

**Entry:** `GET /admin/login`, `POST /admin/login`, `DELETE /admin/logout`

1. **Trigger** — the admin opens the login page. If they are already logged in, they are redirected to `/admin`. · `lib/c3_web/controllers/admin_session_controller.ex:new`
2. **Guard** — the `:admin` pipeline returns a 404 when the admin is disabled. The login itself is then rate-limited to `@login_limit` (10) tries per minute per IP, keyed `{:admin_login, ip}`. This limit stacks on the per-IP limit that every `/admin` route already has. · `lib/c3_web/plugs/admin_enabled.ex:call`, `lib/c3_web/controllers/admin_session_controller.ex:create`
3. **Logic** — the submitted token is trimmed and compared in constant time against the configured token. · `lib/c3/admin.ex:valid_token?`
4. **Persist** — the cookie does not store the token. It stores an HMAC fingerprint of the token plus the login time. A login holds only while that fingerprint still matches and the time is within `admin_session_ttl`. Rotating the token therefore ends every login. · `lib/c3/admin.ex:fingerprint`, `lib/c3/admin.ex:valid_login?`, `lib/c3_web/admin_auth.ex:log_in`
5. **Notify** — the server logs `Logger.info` on success and `Logger.warning` on failure, each with the IP. · `lib/c3_web/controllers/admin_session_controller.ex:create`
6. **Respond** — success redirects to `/admin`. A wrong token re-renders the form with status `401`. Hitting the rate limit re-renders it with `429` and a `retry-after` header. The form is in `lib/c3_web/controllers/admin_session_html/new.html.heex`. Logout drops the whole cookie session. · `lib/c3_web/controllers/admin_session_controller.ex:delete`, `lib/c3_web/admin_auth.ex:log_out`

**Touch this flow when:** changing login throttling, the session TTL, token rotation, or adding real admin users.
**Breaks when:** `C3_ADMIN_TOKEN` is unset, so every `/admin` path is a 404 rather than a login page. A POST without a `login.token` param is treated as an empty token (`create/2` fallback clause), so it returns 401, not 400.

## Flow: see every session and the bans in force

**Entry:** `live "/admin"` → `C3Web.Admin.SessionsLive :index`

1. **Trigger** — the admin opens `/admin`. · `lib/c3_web/live/admin/sessions_live.ex:mount`
2. **Guard** — the `on_mount` hook of the `live_session :admin` checks the login. · `lib/c3_web/admin_auth.ex:on_mount`
3. **Logic** — one aggregate query lists every session still in the database: open sessions, plus closed ones still within retention. Ordering is `status` descending, then `last_activity_at`, with agent and thread counts per session. Bans come from `Security`, metrics from `C3.Metrics.snapshot/0`. · `lib/c3/admin.ex:list_sessions`, `lib/c3/admin.ex:list_active_bans`, `lib/c3_web/live/admin/sessions_live.ex:load`
4. **Notify** — the page subscribes to the `admin` topic. A `{:c3_events, …}` or `{:c3_admin, …}` message does not trigger a query. It only schedules one reload at most every `@debounce_ms` (1 s). A `:tick` every 30 s reloads too, because last activity and ban expiries change without emitting an event. · `lib/c3/events.ex:subscribe_admin`, `lib/c3_web/live/admin/sessions_live.ex:handle_info`
5. **Render** — sessions, metrics and bans are rendered as streams with `reset: true`. The status badges come from `lib/c3_web/live/admin/components.ex:session_status`. Byte sizes are formatted by `lib/c3_web/live/admin/components.ex:format_bytes`.

**Touch this flow when:** adding a column, a filter, or a metric tile, or when the list gets slow with many sessions. The query is unpaginated `Repo.all`.
**Breaks when:** a new metric label is missing from `C3.Metrics.snapshot/0`. The template reads fields such as `@metrics.gauges.sessions_open` directly, so a missing one crashes the render. See [`metrics`](../metrics/00-INDEX.md).

## Flow: lift an IP ban

**Entry:** `phx-click="unban"` on the sessions list

1. **Trigger** — the admin clicks Unban and confirms the `data-confirm` prompt. · `lib/c3_web/live/admin/sessions_live.ex:handle_event`
2. **Logic / persist** — sets `lifted_at` on the bans and removes them from the ban cache. The ban is per IP, so this lifts every ban on that IP. · `lib/c3/admin.ex:unban`
3. **Notify** — no session event is written. Only `{:c3_admin, {:unbanned, ip}}` is broadcast. · `lib/c3/events.ex:notify_admin`
4. **Respond** — a flash shows "Lifted…" or "…was not banned", depending on the count, and the page reloads at once.

**Touch this flow when:** changing ban scope, for example IPv6 networks: the button sends `ban.ip`, not `ip_full`. Ban mechanics belong to [join-security](../join-security/01-flows.md).
**Breaks when:** _(undetermined)_ — no failure clause exists. `Admin.unban/1` always returns `{:ok, n}`.

## Flow: watch one session live

**Entry:** `live "/admin/sessions/:code"` and `live "/admin/sessions/:code/threads/:number"` → `C3Web.Admin.SessionLive`

1. **Trigger** — the admin opens a session from the list. · `lib/c3_web/live/admin/session_live.ex:mount`
2. **Guard** — `on_mount :require_admin`. The code is normalized like a join code. If it is unknown, the page flashes and navigates back to `/admin`. · `lib/c3/admin.ex:get_session`
3. **Logic** — the page subscribes to `admin` *before* the first read, so no event falls between the read and the subscription. It then loads the newest `@page` (100) events, the agents, and the threads with their derived state. · `lib/c3/admin.ex:list_threads`, `lib/c3_web/live/admin/session_live.ex:load_threads`
4. **Thread pick** — `handle_params` with `number` loads one thread and its messages. A non-integer or unknown number flashes and patches back to the session URL. · `lib/c3/admin.ex:get_thread`, `lib/c3_web/live/admin/session_live.ex:handle_params`
5. **Notify** — `{:c3_events, id, seq}` for this session with a `seq` beyond `last_seq` runs `list_after`, in pages of 100. The page streams the new events into the log, then marks agents, threads, or the selected thread as stale according to `@agent_types` and `@thread_types`. It reloads them once per `@debounce_ms` (300 ms). A 30 s `:tick` refreshes the session row and the agents, for `last_seen_at`. · `lib/c3_web/live/admin/session_live.ex:fetch_events`, `lib/c3_web/live/admin/session_live.ex:schedule_reload`
6. **Render** — the log shows newest events first. `load_older` appends older pages using `oldest_seq`. Event rendering is `lib/c3_web/live/admin/components.ex:event_summary`.

**Touch this flow when:** adding a new event type. It must go into `@agent_types` or `@thread_types`, or the matching panel will not refresh. It also needs a clause in `event_summary`.
**Breaks when:** the session is purged while the page is open. `reload_session` finds `nil`, flashes "is gone (purged)", and navigates away, so the page cannot stay on a purged session. The event feed itself is owned by [event-feed](../event-feed/01-flows.md).

## Flow: act on a session (close, unlock joins, finish thread, revoke agent)

**Entry:** `phx-click` = `close_session` | `unlock_joins` | `finish_thread` | `revoke` on the session page

1. **Trigger** — a button with `data-confirm`. Buttons only render when the action applies: Close only on open sessions, Unlock only on open sessions whose joins are locked. · `lib/c3_web/live/admin/session_live.ex:render`
2. **Logic** — each action calls one wrapper in `C3.Admin`:
   - close: `lib/c3/admin.ex:close_session`, which runs `close_session!` in a transaction with reason `:admin`.
   - unlock: `lib/c3/admin.ex:unlock_joins`, which returns `{:ok, true | false}`.
   - finish: `lib/c3/admin.ex:finish_thread`, which cancels the thread's pending requests.
   - revoke: `lib/c3/admin.ex:revoke_agent`. The agent is looked up by matching `to_string(id)` against `Sessions.list_agents`.
3. **Persist / notify** — the domain functions write the same events as their non-admin versions: `session.closed`, `agent.revoked`, and so on. Those events come back over PubSub and refresh the page through the previous flow. · see [session-lifecycle](../session-lifecycle/01-flows.md), [sessions-and-agents](../sessions-and-agents/01-flows.md), [threads-and-requests](../threads-and-requests/01-flows.md)
4. **Respond** — each action shows a flash. Close assigns the returned session. Unlock re-reads the session. Finish patches `finished_at` locally before the event arrives. Revoke reloads the agents. · `lib/c3_web/live/admin/session_live.ex:handle_event`

**Touch this flow when:** adding a new admin action. Add the wrapper in `lib/c3/admin.ex` around an existing domain function rather than writing to the database from the LiveView, so the action keeps leaving its event trace.
**Breaks when:** `finish_thread` fires with no thread selected; that event is silently ignored by the fallback clause. Revoking an agent that is not active returns a generic "not active" error.

## Flow: purge a closed session now

**Entry:** `phx-click="purge_session"` (button shown only when `status == :closed`)

1. **Trigger** — the admin clicks "Purge now" and confirms. · `lib/c3_web/live/admin/session_live.ex:handle_event`
2. **Logic / persist** — the same delete the retention job runs, refused for an open session. · `lib/c3/admin.ex:purge_session`
3. **Notify** — no row is left to hold an event, so `{:c3_admin, {:purged, id}}` is broadcast instead. Any other admin page open on this session also navigates away when it receives that message. · `lib/c3/events.ex:notify_admin`, `lib/c3_web/live/admin/session_live.ex:handle_info`
4. **Respond** — a flash, then a navigation to `/admin`. Any error is shown as "Only a closed session can be purged."

**Touch this flow when:** changing retention or what a purge deletes; both are owned by [session-lifecycle](../session-lifecycle/01-flows.md).
**Breaks when:** _(undetermined)_ — beyond the open-session refusal, no failure path was found.

## Flow: download an attachment as the admin

**Entry:** `GET /admin/sessions/:code/attachments/:id`

1. **Trigger** — the admin follows an attachment link on the session page. · `lib/c3_web/controllers/admin_attachment_controller.ex:show`
2. **Guard** — the request runs through the `:admin` pipeline, then the `plug :require_admin` controller plug. It is outside the `live_session`, so the `on_mount` hook does not apply here. · `lib/c3_web/admin_auth.ex:require_admin`
3. **Logic** — the session is resolved by code and the attachment is fetched within that session's id. An attachment from another session cannot be fetched. · `lib/c3/admin.ex:get_session`
4. **Respond** — the response uses the same headers an agent gets, via `lib/c3_web/controllers/v1/attachment_controller.ex:send_attachment`. An unknown session or attachment returns a plain-text `404 Not found`.

**Touch this flow when:** changing attachment headers or storage; both are owned by [attachments](../attachments/01-flows.md).
**Breaks when:** the admin's login has expired. Unlike the LiveViews, this route has no live socket, so the plug decides on every request.

## Shared state

- **`admin` PubSub topic.** It carries every session's `{:c3_events, id, seq}` announcement plus admin-only notices. The topic is owned by [event-feed](../event-feed/01-flows.md) through `lib/c3/events.ex:subscribe_admin` and `lib/c3/events.ex:notify_admin`.
- **Bans and the ban cache.** Owned by [join-security](../join-security/01-flows.md).
- **Metrics snapshot** read by the sessions list. Owned by [`metrics`](../metrics/00-INDEX.md).
- **Config keys `admin_token` and `admin_session_ttl`.** They are read through `C3.Config` in `lib/c3/admin.ex:enabled?` and `lib/c3/admin.ex:valid_login?`.
