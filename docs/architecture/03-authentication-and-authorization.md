---
doc: architecture/03-authentication-and-authorization
repo: c3
kind: architecture
anchored_to: fcd0bd9
generated: 2026-10-02
---
# How an agent, an admin and a metrics scraper are identified, and what each check blocks and returns

C3 has no user accounts. It recognises three kinds of caller, and each one proves who it is differently. An **agent** proves it once with the session code plus the numeric secret, and from then on with a bearer token. An **admin** proves it with `C3_ADMIN_TOKEN`, once, and gets a signed cookie in exchange. A **metrics scraper** sends `C3_METRICS_TOKEN` as a bearer token on every request. The checks are kept separate so that one credential can never stand in for another. They are also deliberately lenient in one place: a valid agent token is never blocked by an IP ban.

## How it works

**Agent credentials.** `lib/c3/credentials.ex:C3.Credentials` creates and hashes the three credentials of a session:

- The session code (`generate_code`) is `C3-XXXX-XXXX`: 40 random bits in Crockford base32, stored in clear. `normalize_code` accepts the code as a person might type it: any letter case, any separators, an optional `C3` prefix, and the look-alikes `O`→`0` and `I`/`L`→`1`.
- The secret (`generate_secret`) is short and numeric. It is stored only as an Argon2id hash (`hash_secret`), because a low-entropy value needs a slow hash. `verify_secret` ignores spaces, and its fallback clause calls `Argon2.no_user_verify()`. `dummy_verify` is meant to spend the same time when the code is unknown. The secret is only checked when an agent joins.
- When an agent creates or joins a session it gets a token from `generate_token`: `"c3_"` followed by 32 random bytes in url-safe base64. Only its SHA-256 is stored (`hash_token`). Because the token has high entropy, a fast deterministic hash is enough, and that lets `lib/c3/sessions.ex:get_agent_by_token` find the agent with a plain lookup on `token_hash`. No Argon2 runs on the request path.

**Every authenticated agent request.** `lib/c3_web/plugs/agent_auth.ex:C3Web.Plugs.AgentAuth` reads `Authorization: Bearer <token>` and checks, in this order:

1. The header is missing or empty, or no agent has that token → **401** `unauthorized`.
2. The route has a `:code` and it does not match the token's session (compared after `normalize_code`) → **403** `forbidden`. Routes without `:code` (`/threads/:id`, `/inbox`) take the session from the token.
3. The session is closed → **410** `session_closed`, on every route. This comes before the agent-status check, so tokens that the close revoked also get 410, not 401.
4. The agent is not `:active` (it left or was revoked) → **401** `unauthorized`.
5. Otherwise the plug assigns `current_agent` and `current_session`.

On success the plug records two separate things:

- **Presence**: `lib/c3/sessions.ex:touch_seen` updates `last_seen_at`, at most once every `last_seen_throttle` seconds (about 60). This is what keeps the agent's claims from expiring.
- **Activity**: `lib/c3/sessions.ex:touch_activity` updates `last_activity_at`, which postpones the session's idle close. It is skipped when the plug is mounted with `activity: false`.

The router's `:feed` pipeline mounts the plug with `activity: false` (`lib/c3_web/router.ex:pipeline :feed`). That pipeline covers `/events`, `/heartbeat`, `/events/stream` and `/watch`, so a watcher left running proves the agent is alive without keeping a forgotten session open.

**IP bans.** Bans are checked only at create and join (`lib/c3/sessions.ex:banned_until`, which returns `{:error, :ip_banned, until}`). `AgentAuth` never looks at the caller's IP. Machines behind one public IP can share a ban without losing tokens they already hold. Ban rules belong to the security feature (`lib/c3/security.ex:C3.Security`).

**MCP.** On `/mcp` the agent token is a tool **argument** (`lib/c3_web/mcp/tools.ex:@token`), never an HTTP header. `lib/c3_web/mcp/dispatch.ex:C3Web.MCP.Dispatch` then turns it into an `authorization` header on an in-process `/v1` request, so it goes through the same `AgentAuth` checks. A 401 on the `/mcp` transport itself would make the MCP client start its OAuth flow.

**Admin.**

- `lib/c3_web/plugs/admin_enabled.ex:C3Web.Plugs.AdminEnabled` answers **404** (an HTML error page) on every `/admin` route, the login page included, while `lib/c3/admin.ex:enabled?` is false, meaning `C3_ADMIN_TOKEN` is unset.
- Login: `lib/c3/admin.ex:valid_token?` compares the token in constant time. Then `lib/c3_web/admin_auth.ex:log_in` renews and clears the session (protection against session fixation) and stores two values: `"c3_admin"`, which is `lib/c3/admin.ex:fingerprint` (an HMAC-SHA256 of the admin token under `"c3 admin session"`), and `"c3_admin_at"`, the login time. The cookie never holds the token itself.
- `lib/c3/admin.ex:valid_login?` requires the stored fingerprint to match the current one and the login to be younger than `admin_session_ttl`. Rotating `C3_ADMIN_TOKEN` therefore logs everyone out.
- `lib/c3_web/admin_auth.ex:on_mount` with `:require_admin` checks the login on every LiveView mount and reconnection. It also attaches `check_login` to `handle_event`, so every action re-checks expiry. A failed check redirects to `/admin/login`; it never returns 401.

**Metrics.** `lib/c3_web/controllers/metrics_controller.ex:show` answers:

- **404** `not_found` when `C3_METRICS_TOKEN` is unset.
- **401** `unauthorized`, with `www-authenticate: Bearer realm="c3-metrics"`, when the bearer token is missing or wrong. The comparison is `secure_compare`.

## The pieces

| Path | Export | Role |
|---|---|---|
| `lib/c3/credentials.ex` | `generate_code`, `normalize_code` | Create the session code and parse it as typed. |
| `lib/c3/credentials.ex` | `hash_secret`, `verify_secret`, `dummy_verify` | Argon2id hashing and checking of the secret; used at join only. |
| `lib/c3/credentials.ex` | `generate_token`, `hash_token` | Create the 256-bit agent token and its SHA-256 lookup key. |
| `lib/c3_web/plugs/agent_auth.ex` | `C3Web.Plugs.AgentAuth` | Bearer token → agent; returns 401/403/410/401; records presence and, optionally, activity. |
| `lib/c3_web/admin_auth.ex` | `log_in`, `log_out`, `logged_in?` | Admin cookie holding the fingerprint and login time. |
| `lib/c3_web/admin_auth.ex` | `on_mount`, `require_admin` | Guard the admin LiveViews (including each event) and controller actions. |
| `lib/c3_web/plugs/admin_enabled.ex` | `C3Web.Plugs.AdminEnabled` | 404 for all of `/admin` while there is no admin token. |

## How a feature uses it

A REST route opts in by sitting under a pipeline that includes `AgentAuth`: `:agent`, `:agent_no_replay` or `:feed` in `lib/c3_web/router.ex`. The controller then reads `conn.assigns.current_agent` and `conn.assigns.current_session`. A route outside those pipelines has no assigned agent.

```elixir
pipeline :feed do
  plug C3Web.Plugs.AgentAuth, activity: false
  plug C3Web.Plugs.RateLimit, :token
end
```

An admin page goes inside `live_session :admin, on_mount: {C3Web.AdminAuth, :require_admin}`. An admin controller action uses `plug :require_admin`.

## Rules

1. Never use Argon2 (or any salted hash) for tokens. The lookup by `token_hash` depends on `hash_token` being deterministic; with a salted hash, every token would return 401.
2. Never check IP bans in `AgentAuth`. Machines sharing a public IP would lose live sessions because of one bad join.
3. Mount `activity: false` on anything a background watcher calls. Otherwise an abandoned watcher keeps the session alive until its maximum TTL.
4. Keep the closed-session check before the agent-status check. Otherwise revoked tokens get 401 instead of 410, and clients cannot tell that the session ended.
5. Never put the admin token in the session cookie. Rotating the token is the only way to log everyone out.
6. On `/mcp`, never require an `Authorization` header and never return 401 from the transport. Clients would start an OAuth flow that C3 does not have.

## Gotchas

- A 410 can come from any agent route, including `/inbox` and `/threads/:id`, not only routes that carry `:code`.
- Both throttled writes compare against the value already loaded. Within about 60 seconds, the returned agent and session carry the old timestamps.
- `touch_activity` reuses `last_seen_throttle`; it has no throttle setting of its own.
- `/admin` without a token returns an HTML 404. `/metrics` without a token returns a JSON 404 from `ApiError`.
- `bearer` in `AgentAuth` accepts only a single `Authorization` header. The metrics controller takes the first of several.
- The admin login is checked again on every LiveView event. An expired login fails at the next click, not at the next page load.

## Who uses it

| Feature | Uses it for |
|---|---|
| REST API (`lib/c3_web/router.ex:pipeline :agent`) | Agent identity on every `/v1` call after join. |
| Event feed / watcher (`lib/c3_web/router.ex:pipeline :feed`) | Presence without activity. |
| Remote MCP (`lib/c3_web/mcp/dispatch.ex`) | The token argument goes through the same `AgentAuth` checks. |
| Admin UI (`lib/c3/admin.ex`) | Token login, fingerprint cookie, guarded LiveViews. |
| Metrics (`lib/c3_web/controllers/metrics_controller.ex`) | Bearer `C3_METRICS_TOKEN`; 404/401. |
| Security (`lib/c3/security.ex`) | IP bans at create/join only. |
