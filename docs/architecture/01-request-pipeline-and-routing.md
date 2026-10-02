---
doc: architecture/01-request-pipeline-and-routing
repo: c3
kind: architecture
anchored_to: e99b2ae
generated: 2026-10-02
---
# Request pipeline and routing

Every HTTP request goes through the same path: the endpoint's plug chain, then one or more router pipelines, then a controller. Each pipeline handles one cross-cutting concern: the client IP, rate limits, agent auth, `Idempotency-Key` replay, and the MCP origin guard. All failures come back in one stable JSON error shape. Most of the routing is ordinary Phoenix. Some parts look like mistakes, but each one is there on purpose, and "fixing" it breaks real clients.

## How it works

**Endpoint.** `lib/c3_web/endpoint.ex:C3Web.Endpoint` runs the plugs in this order:
1. `Plug.Static`
2. In development only, the code reloader plugs
3. `Plug.RequestId` and `Plug.Telemetry`
4. `C3Web.Plugs.Parsers`
5. `Plug.MethodOverride`, `Plug.Head` and `Plug.Session`
6. `C3Web.Router`

The body is parsed before routing starts. That is why the body size limit is chosen by path in `lib/c3_web/plugs/parsers.ex:carries_attachments?` and not per pipeline:
- **1 MB** by default (`@default_length`).
- **`C3.Config.attachments_request_max_bytes/0`** on three routes, because they can carry inline attachments:
  - `POST /v1/threads/:id/messages`
  - `POST /v1/sessions/:code/threads`
  - `POST /mcp`, because MCP tool calls can post messages too.

A body over the limit gets a `413 too_large`, rendered by `lib/c3_web/controllers/error_json.ex:C3Web.ErrorJSON`. Smaller per-message limits are enforced later, outside this mechanism.

**Pipelines**, in the order `lib/c3_web/router.ex:C3Web.Router` declares them:

| Pipeline | Plugs, in order | What it enforces |
|---|---|---|
| `:browser` | `accepts ["html"]`, session, flash, root layout, `protect_from_forgery`, secure headers | Standard HTML pages: `/` and the admin pages |
| `:api` | `accepts ["json"]` | Used only by `/healthz` |
| `:v1` | `accepts ["json"]`, `C3Web.Plugs.RealIp`, `C3Web.Plugs.RateLimit, :ip` | Every JSON `/v1` route: the rate limit per client IP |
| `:agent` | `C3Web.Plugs.AgentAuth`, `RateLimit, :token`, `C3Web.Plugs.Idempotency` | Requires a Bearer token, applies the rate limit per agent, and replays `Idempotency-Key` |
| `:agent_no_replay` | `AgentAuth`, `RateLimit, :token` | Like `:agent` but without `Idempotency`. Used only by `rotate-secret` |
| `:feed` | `AgentAuth, activity: false`, `RateLimit, :token` | Counts as a sign of life from the agent, but not as activity on the session, so a watcher left running does not keep an idle session open |
| `:sse` | `RealIp`, `RateLimit, :ip` | Like `:v1` but **without `accepts`**. Used for `/metrics`, the event stream, `/watch` and the attachment download |
| `:mcp` | `C3Web.Plugs.Origin`, `RealIp`, `RateLimit, :ip` | DNS-rebinding guard, then the IP limit. No `accepts` |
| `:admin` | `C3Web.Plugs.AdminEnabled`, `RealIp`, `RateLimit, :ip` | Returns 404 for everything while the admin token is unset |

Pipelines are combined per scope:
- `/v1` session create and join use `:v1` only.
- Authenticated `/v1` routes use `:v1` followed by `:agent`, `:agent_no_replay` or `:feed`.
- `/v1/sessions/:code/events/stream` and `/watch` use `[:sse, :feed]`.
- `/v1/attachments/:id` uses `[:sse, :agent]`.
- `/admin` uses `[:browser, :admin]`.

**Client IP.** `lib/c3_web/plugs/real_ip.ex:client_ip` sets `conn.assigns.client_ip`:
- With no real-IP header configured, it uses the peer address.
- With a header configured, the header is read only when the peer is in the trusted-proxy list. The comma-separated entries are reversed, and the first one that is not a trusted proxy wins.
- If every entry is trusted, the left-most entry is used. If the header is empty or invalid, the peer address is used.

Because the list is read from the right, a client cannot spoof its address by putting extra entries at the front.

**Rate limit.** `lib/c3_web/plugs/rate_limit.ex:limit` calls `lib/c3/rate_limiter.ex:hit`, a fixed-window counter in ETS:
- The key is `{:ip, CIDR.subject(ip)}`, so IPv6 clients are grouped by network prefix.
- Or the key is `{:token, current_agent.token_hash}`, so the token hash and not the agent id.
- Over the limit: `429 rate_limited` with a `retry-after` header and `details.retry_after`.
- Under `/admin` the 429 is plain text instead of JSON (`reject/2`).
- Counters are lost on restart, which is acceptable. The `:sweep` handler drops finished windows every minute.

**Idempotency.** `lib/c3_web/plugs/idempotency.ex:C3Web.Plugs.Idempotency` acts only on `POST` requests that carry an `Idempotency-Key` header:
- Keys must be 1–100 characters (`@max_key`), otherwise `400`.
- The request hash (`request_hash/1`) is SHA-256 of `:erlang.term_to_binary({method, request_path, query_string, body_params}, [:deterministic])`. The same JSON with its keys in a different order gives the same hash.
- Same key, same hash: the stored response is replayed with an `idempotent-replayed: true` header.
- Same key, different hash: `422 invalid_request`.
- Unknown key: `lib/c3/idempotency.ex:begin` puts an in-flight mark in ETS. While the first request is still running, a second copy gets `409 conflict`. A mark older than `@stale_ms` (60 s) is treated as stale and taken over.
- In `register_before_send`, the response is stored only when `status < 500` and the body decodes to a JSON map. The in-flight mark is always cleared.
- Stored responses are rows of `lib/c3/sessions/idempotency_key.ex:C3.Sessions.IdempotencyKey`, unique on `[:agent_id, :key]` and inserted with `on_conflict: :nothing`.
- `lib/c3/idempotency.ex:purge` deletes rows older than `@ttl_seconds` (24 h).

**Errors.** Every API error has the shape `{"error": {"code", "message", "details"?}}`, built by `lib/c3_web/api_error.ex:body`. Errors come from three places:
- Plugs call `lib/c3_web/api_error.ex:send_error`, which also halts the request.
- Controllers return `{:error, …}`, and `lib/c3_web/controllers/v1/fallback_controller.ex:C3Web.V1.FallbackController` maps it to an error response.
- Errors Phoenix raises itself (no route, a body that does not parse, a crash, 406, 413, 415) are rendered by `lib/c3_web/controllers/error_json.ex:render`, which maps the status to a code through `@codes`. Any unmapped status becomes `internal_error`.

| Code | Status | Typical origin |
|---|---|---|
| `invalid_request` | 400 / 422 (and 406 / 415 from `ErrorJSON`) | Bad key, changeset error, `{:invalid, …}`, reused key |
| `unauthorized` | 401 | `AgentAuth` |
| `invalid_secret`, `ip_banned`, `forbidden` | 403 | Fallback; `ip_banned` carries `details.banned_until` |
| `not_found` | 404 | Session, thread or attachment |
| `conflict` | 409 | Idempotency key in flight, `{:conflict, …}` |
| `session_closed` | 410 | `AgentAuth`, fallback |
| `too_large` | 413 | Parsers, `{:too_large, …}` |
| `joins_locked` | 423 | Fallback |
| `rate_limited` | 429 | `RateLimit` |
| `internal_error` | 500 | `ErrorJSON` |

The one exception is `C3Web.Plugs.Origin`. Its 403 is a JSON-RPC error (`code: -32600`), not the API shape, because only MCP clients reach it.

## The pieces

| Path | Export | Role |
|---|---|---|
| `lib/c3_web/endpoint.ex` | `C3Web.Endpoint` | The plug chain; parses the body before routing |
| `lib/c3_web/router.ex` | `C3Web.Router` | Pipelines and scopes |
| `lib/c3_web.ex` | `C3Web` | The `use C3Web, :router` / `:controller` macros |
| `lib/c3_web/plugs/parsers.ex` | `C3Web.Plugs.Parsers` | Body size limit chosen by path |
| `lib/c3_web/plugs/real_ip.ex` | `C3Web.Plugs.RealIp` | Sets `client_ip`; trusts the header only from a trusted proxy |
| `lib/c3_web/plugs/rate_limit.ex` | `C3Web.Plugs.RateLimit` | `:ip` / `:token` limits, 429 |
| `lib/c3/rate_limiter.ex` | `C3.RateLimiter.hit/3` | Fixed-window ETS counters |
| `lib/c3_web/plugs/origin.ex` | `C3Web.Plugs.Origin` | MCP `Origin` allowlist |
| `lib/c3_web/plugs/idempotency.ex` | `C3Web.Plugs.Idempotency` | Replay, conflict and storage of `Idempotency-Key` responses |
| `lib/c3/idempotency.ex` | `C3.Idempotency` | In-flight ETS mark, DB storage, `purge/1` |
| `lib/c3/sessions/idempotency_key.ex` | `C3.Sessions.IdempotencyKey` | The stored response row |
| `lib/c3_web/api_error.ex` | `C3Web.ApiError` | The error shape: `body/3`, `send_error/5` |
| `lib/c3_web/controllers/v1/fallback_controller.ex` | `C3Web.V1.FallbackController` | Maps a context's `{:error, …}` to an `ApiError` response |
| `lib/c3_web/controllers/error_json.ex` | `C3Web.ErrorJSON` | Renders errors Phoenix raises in the API shape |
| `lib/c3_web/controllers/error_html.ex` | `C3Web.ErrorHTML` | HTML error pages, used by `AdminEnabled` |

## How a feature uses it

To add an authenticated `/v1` endpoint, put the route inside the `pipe_through :agent` scope. The controller then reads `conn.assigns.current_agent` and `current_session`, and returns `{:error, …}` tuples that `FallbackController` already understands:

```elixir
scope "/" do
  pipe_through :agent
  post "/threads/:id/claim", ThreadController, :claim
end
```

Where the route goes changes what it gets:
- Outside every agent scope: no auth, and only the IP limit applies.
- Under `:feed`: the request does not postpone the session's idle close.
- A new error atom must get a `call/2` clause in `FallbackController`. Without one, the request crashes and the client gets a 500.

## Rules

1. **Routes that do not answer JSON must not go through `:v1`/`accepts`.** This covers SSE, `/watch`, `/mcp`, `/metrics` and attachment downloads. Clients send `Accept: text/event-stream` or `text/plain`, and `accepts ["json"]` answers those with `406`. For `/mcp`, a legacy client's `GET` must get `405`, not `406`.
2. **`rotate-secret` stays on `:agent_no_replay`.** Storing its response would keep the new secret in clear in `idempotency_keys` for 24 h. A retry simply rotates again.
3. **`RealIp` runs before `RateLimit, :ip`.** The IP limit reads `conn.assigns.client_ip`; without it the request crashes.
4. **`AgentAuth` runs before `RateLimit, :token` and `Idempotency`.** Both read `current_agent`.
5. **Every API error goes through `ApiError`.** Clients branch on `error.code`. A hand-built error body breaks them silently.
6. **A new route that accepts inline attachments must be added to `carries_attachments?`.** Otherwise it is cut off at 1 MB with a `413`.

## Gotchas

- **The body is parsed before the router.** A pipeline cannot raise or lower the size limit. Only the path match in `Parsers` can.
- **The rate-limit key is `token_hash`, not the agent id.** If the secret is rotated, the agent gets a fresh token and a fresh bucket.
- **MCP tool calls count against the IP limit once, at `/mcp`.** They are dispatched in-process as `/v1` requests with `private.c3_mcp`. For those requests, `RealIp` keeps the IP that `/mcp` already resolved and `RateLimit, :ip` does nothing, but the `:token` limit still counts.
- **The in-flight 409 only works on a single node.** The mark lives in this node's ETS. With two nodes, both copies of a request would run. The database's `on_conflict: :nothing` keeps the first stored response, but the side effect still happens twice.
- **5xx responses are never stored**, so a retry after a server error really runs again. Bodies that are not JSON maps are not stored either.
- **`Idempotency` ignores non-`POST` requests**, even under `:agent`. A `GET` with the header is not affected.
- **`Origin` passes any request without an `Origin` header.** Agents never send one. The guard only stops browser pages.
- **`AgentAuth` does not check IP bans.** A live token still works from a banned IP.
- **The admin pages return 429 as plain text, not JSON.**
- **The `ErrorJSON` message is the standard HTTP status phrase**, not a domain message.

## Who uses it

| Feature | Uses it for |
|---|---|
| Sessions (create, join, rotate-secret, close) | The `:v1` IP limit; ban, secret and lock errors through the fallback; replay is skipped for rotate-secret |
| Threads and messages | `:agent` auth, replay and the larger body limit for attachments |
| Event feed and watcher | `[:sse, :feed]`: no `accepts`, and the feed does not count as session activity |
| Attachments | `[:sse, :agent]` for downloads, the larger body limit for uploads |
| MCP endpoint | `:mcp` pipeline, `Origin`, and in-process dispatch that skips the IP limit |
| Admin | `AdminEnabled`, the IP limit with plain-text 429 |
| Metrics | `:sse`, so Prometheus text is not rejected by `accepts` |
