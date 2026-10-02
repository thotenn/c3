---
doc: architecture/01-request-pipeline-and-routing
repo: c3
kind: architecture
anchored_to: fcd0bd9
generated: 2026-10-02
---
# How an HTTP request enters c3 — endpoint, router pipelines, plugs, and the stable error shape

Every HTTP request goes through one plug chain in `lib/c3_web/endpoint.ex:C3Web.Endpoint`. Then one or more named pipelines in `lib/c3_web/router.ex:C3Web.Router` run, and only after that does a controller action run. The pipelines handle the cross-cutting work: they resolve the real client IP, rate-limit, authenticate the agent, replay `Idempotency-Key` retries and guard `/mcp` against DNS rebinding. Every API failure, whether it comes from a plug, a controller or a Phoenix exception, uses one JSON shape: `{"error": {"code", "message", "details"?}}`. Clients depend on that shape staying the same.

## How it works

**Endpoint chain** (`lib/c3_web/endpoint.ex:C3Web.Endpoint`), in order:
1. `socket "/live"` handles the LiveView socket.
2. `Plug.Static` serves only `lib/c3_web.ex:static_paths`.
3. In dev only: the code reloader and `Phoenix.Ecto.CheckRepoStatus`.
4. `Plug.RequestId`, then `Plug.Telemetry`.
5. `C3Web.Plugs.Parsers`.
6. `Plug.MethodOverride`, `Plug.Head` and `Plug.Session` (a signed cookie, `_c3_key`).
7. The router.

The body is parsed in the endpoint, before any route is matched. That is why the body-size limit depends on the request path and not on the route (see Parsers below).

**Body limit.** `lib/c3_web/plugs/parsers.ex:carries_attachments?` checks whether the request is a `POST` to one of these paths:
- `/v1/threads/:id/messages`
- `/v1/sessions/:code/threads`
- `/mcp`

If it is, the limit is `C3.Config.attachments_request_max_bytes/0`, because those routes carry attachments inline. Every other request gets `@default_length` (1 MB). A body over the limit is a 413, which `lib/c3_web/controllers/error_json.ex:C3Web.ErrorJSON` renders as `too_large`. The per-message body limit is enforced later, in the contexts, and is not covered here.

**Router pipelines** (`lib/c3_web/router.ex`), in declaration order:

| Pipeline | Plugs, in order | What it enforces |
|---|---|---|
| `:browser` | `accepts ["html"]`, `fetch_session`, `fetch_live_flash`, `put_root_layout`, `protect_from_forgery`, `put_secure_browser_headers` | CSRF and secure headers for `/` and `/admin` |
| `:api` | `accepts ["json"]` | `/healthz` only |
| `:v1` | `accepts ["json"]`, `RealIp`, `RateLimit :ip` | Applies to every `/v1` route in the first `/v1` scope, including the unauthenticated `POST /v1/sessions` and `/join` |
| `:agent` | `AgentAuth`, `RateLimit :token`, `Idempotency` | Authenticated agent calls; `POST` retries are replayed |
| `:agent_no_replay` | `AgentAuth`, `RateLimit :token` | `POST /v1/sessions/:code/rotate-secret` only. **No `Idempotency`, on purpose**: a stored response would keep the new secret in clear in `idempotency_keys` for 24 h, so a retry rotates the secret again |
| `:feed` | `AgentAuth, activity: false`, `RateLimit :token` | `/events`, `/heartbeat`, `/events/stream` and `/watch`. Polling shows the agent is alive but does not count as session activity |
| `:sse` | `RealIp`, `RateLimit :ip` | **No `accepts`**: `Accept: text/event-stream` or `text/plain` would get a 406 from `:v1`. Used by `/metrics`, by `[:sse, :feed]` for `/events/stream` and `/watch`, and by `[:sse, :agent]` for `GET /v1/attachments/:id`, which answers with the file's own content type |
| `:mcp` | `Origin`, `RealIp`, `RateLimit :ip` | **No `accepts`**: a legacy client's `GET /mcp` (`Accept: text/event-stream`) has to reach `MCPController :not_allowed` and get a 405, not a 406 |
| `:admin` | `AdminEnabled`, `RealIp`, `RateLimit :ip` | Runs after `:browser`. Returns 404 while the admin token is unset |

`/dev/dashboard` is mounted only when the compile-time `:dev_routes` setting is on.

**Real client IP.** `lib/c3_web/plugs/real_ip.ex:client_ip` writes `conn.assigns.client_ip`.
- With no real-IP header configured, the client IP is `conn.remote_ip` (the peer).
- With a header configured, the header is read only when the peer belongs to the trusted-proxy CIDRs.
- Its comma-separated entries are parsed, entries that don't parse are dropped, and the list is walked **right-to-left**. The first address that is not a trusted proxy wins.
- If every entry is trusted, it falls back to the leftmost entry, and then to the peer.

Walking from the right means a client cannot spoof its address by prepending entries to the header.

**Rate limit.** `lib/c3_web/plugs/rate_limit.ex:call` uses two keys:
- `{:ip, client_ip}`.
- `{:token, current_agent.token_hash}`. This is the token **hash**, not the agent id, so the limit follows the credential.

Both keys go to `lib/c3/rate_limiter.ex:hit`, a fixed-window ETS counter keyed by `{key, window_ms, window}`. A sweep every minute deletes finished windows. When the limit is exceeded, the response is a 429 with a `retry-after` header (in seconds, at least 1) and `details.retry_after`. Under `/admin` the 429 is plain text instead (`lib/c3_web/plugs/rate_limit.ex:reject`).

**Idempotency.** `lib/c3_web/plugs/idempotency.ex:call` acts only on `POST` requests that carry an `Idempotency-Key` header:
1. The key is trimmed. It must be 1 to 100 bytes, otherwise the response is 400 `invalid_request`.
2. `request_hash` is the SHA-256 of `{method, request_path, query_string, body_params}`, encoded with `:erlang.term_to_binary(_, [:deterministic])`. The same JSON with its keys in another order therefore hashes the same.
3. `lib/c3/idempotency.ex:lookup` looks for a stored response:
   - Same hash: the stored status and body are replayed, with the `idempotent-replayed: true` header.
   - Different hash: 422 `invalid_request`.
   - No stored row: `lib/c3/idempotency.ex:begin` places an in-flight mark in ETS. If the mark already exists, the response is 409 `conflict`. A mark older than `@stale_ms` (60 s) is treated as stale and taken over.
4. A `register_before_send` callback stores the response only if its status is below 500 and its body decodes to a JSON object (`lib/c3_web/plugs/idempotency.ex:store`). The callback then clears the mark with `lib/c3/idempotency.ex:finish`.

`lib/c3/idempotency.ex:store` inserts with `on_conflict: :nothing` on `[:agent_id, :key]`. `lib/c3/idempotency.ex:purge` deletes rows older than `@ttl_seconds` (24 h).

**Origin guard.** `lib/c3_web/plugs/origin.ex:call` lets a request with no `Origin` header through; agents don't send one. A request whose `Origin` is not in the allowed list gets a 403 with a **JSON-RPC** error body (`code: -32600`), not the `ApiError` shape.

**Errors.** There are three paths into the stable shape built by `lib/c3_web/api_error.ex:body`:
1. Plugs call `lib/c3_web/api_error.ex:send_error`, which also halts the connection.
2. Controllers that declare `action_fallback C3Web.V1.FallbackController` return `{:error, …}`, and `lib/c3_web/controllers/v1/fallback_controller.ex:call` maps it to a response.
3. Phoenix exceptions and unmatched routes on JSON requests are rendered by `lib/c3_web/controllers/error_json.ex:render`. It maps the status to a code through `@codes`, and any status not in the map becomes `internal_error`.

HTML errors are rendered as plain status text (`lib/c3_web/controllers/error_html.ex:render`).

| Code | Status | Typical source |
|---|---|---|
| `invalid_request` | 400 / 406 / 415 / 422 | Idempotency key format or reuse, `{:invalid, …}`, changeset errors (details hold the field errors) |
| `unauthorized` | 401 | Agent auth |
| `invalid_secret` | 403 | Wrong security number on join; the IP is banned as a result |
| `ip_banned` | 403 | Fallback; `details.banned_until` |
| `forbidden` | 403 | `{:forbidden, msg}` |
| `not_found` | 404 | `:not_found`, `:thread_not_found`, `:attachment_not_found`, no route |
| `conflict` | 409 | `{:conflict, msg, details}`, Idempotency key in flight |
| `session_closed` | 410 | `:session_closed` |
| `too_large` | 413 | Parsers limit, `{:too_large, msg}` |
| `joins_locked` | 423 | `:joins_locked` |
| `rate_limited` | 429 | RateLimit; `details.retry_after` |
| `internal_error` | 500 | Anything unmapped |

## The pieces

| Path | Export | Role |
|---|---|---|
| `lib/c3_web/endpoint.ex` | `C3Web.Endpoint` | Plug chain before routing; body parsing happens here |
| `lib/c3_web/router.ex` | `C3Web.Router` | Pipelines and scopes |
| `lib/c3_web.ex` | `controller`, `router`, `static_paths` | `use C3Web, :controller` gives `formats: [:html, :json]` |
| `lib/c3_web/plugs/parsers.ex` | `C3Web.Plugs.Parsers` | `Plug.Parsers` with a body limit chosen per path |
| `lib/c3_web/plugs/real_ip.ex` | `C3Web.Plugs.RealIp` | Sets `assigns.client_ip` |
| `lib/c3_web/plugs/rate_limit.ex` | `C3Web.Plugs.RateLimit` | `:ip` / `:token` limits |
| `lib/c3/rate_limiter.ex` | `C3.RateLimiter.hit/3` | ETS fixed-window counters (a GenServer owns the table) |
| `lib/c3_web/plugs/origin.ex` | `C3Web.Plugs.Origin` | DNS-rebinding guard for `/mcp` |
| `lib/c3_web/plugs/idempotency.ex` | `C3Web.Plugs.Idempotency` | Replay, reject or store `POST` responses |
| `lib/c3/idempotency.ex` | `lookup/2`, `begin/2`, `finish/2`, `store/5`, `purge/1` | Stored responses plus the in-flight ETS marks |
| `lib/c3/sessions/idempotency_key.ex` | `C3.Sessions.IdempotencyKey` | `idempotency_keys` row, unique on `[:agent_id, :key]` |
| `lib/c3_web/api_error.ex` | `body/3`, `send_error/5` | The stable error shape |
| `lib/c3_web/controllers/v1/fallback_controller.ex` | `C3Web.V1.FallbackController.call/2` | Maps context `{:error, …}` results to `ApiError` |
| `lib/c3_web/controllers/error_json.ex` | `C3Web.ErrorJSON.render/2` | Renders Phoenix-raised errors in the stable shape |
| `lib/c3_web/controllers/error_html.ex` | `C3Web.ErrorHTML.render/2` | Plain status text for HTML requests |

## How a feature uses it

Add the route to the scope whose pipeline matches what the route needs: `:agent` for a normal authenticated call, `:feed` for polling, `[:sse, :agent]` for a response that is not JSON. Declare the fallback controller and return context errors as they are:

```elixir
# lib/c3_web/router.ex, inside scope "/v1" … pipe_through :agent
post "/threads/:id/claim", ThreadController, :claim

# controller
action_fallback C3Web.V1.FallbackController
def claim(conn, params), do: with({:ok, t} <- ..., do: json(conn, ...))
```

If a context returns an `{:error, …}` tuple that `FallbackController.call/2` has no clause for, Phoenix raises a `FunctionClauseError` and the client gets a 500 `internal_error`. Add the clause there.

## Rules

1. **Don't add an `accepts` plug to `:sse`, `:mcp` or the attachment-download scope.** SSE clients, `/watch`, legacy MCP `GET` requests and downloads would start getting 406 instead of their stream, their text or their 405.
2. **Keep `rotate-secret` out of `:agent`.** Under `Idempotency`, the new secret would be stored in clear for 24 h.
3. **`RealIp` must run before `RateLimit :ip`, and `AgentAuth` before `RateLimit :token` and `Idempotency`.** They read `assigns.client_ip` and `assigns.current_agent`; without those assigns the request crashes with a 500.
4. **Every API error goes through `C3Web.ApiError`.** Clients match on `error.code`. The only exception is `Origin`'s JSON-RPC body, which the MCP transport requires.
5. **A new route that carries attachments inline has to be added to `carries_attachments?`.** Otherwise its body is capped at 1 MB and the client gets a 413.
6. **A new `Idempotency-Key` field has to stay in the request hash.** If the hash stops covering a field, a different request is replayed as if it were the same one.

## Gotchas

- The 409 from an in-flight Idempotency key only works **on a single node**. The marks are in local ETS, so two nodes would both run the request. `on_conflict: :nothing` then keeps the first stored response.
- A request that crashes before `before_send` leaves its in-flight mark behind. Retries get 409 for up to 60 s, until the mark goes stale.
- A 5xx is never stored: a retry with the same key actually runs again. A response whose body is not a JSON object is also not stored, and fails silently.
- `RealIp` and `RateLimit :ip` do nothing for requests that `/mcp` dispatches in-process (`private.c3_mcp`). An MCP tool call counts once per IP, at `/mcp`, and once per token on the inner call.
- When every forwarded-header entry is a trusted proxy, the leftmost entry is used, and a client can control that entry.
- Rate-limit counters and in-flight marks are lost on restart. That is intended (`lib/c3/rate_limiter.ex:C3.RateLimiter`).
- `ErrorJSON` maps 406 and 415 to `invalid_request`, and 410 to `session_closed`, even when Phoenix raised the error for some other reason.
- `/metrics` uses `:sse` only to skip `accepts`. It has nothing to do with Server-Sent Events.

## Who uses it

| Feature | Uses it for |
|---|---|
| Sessions (create/join/rotate) | `:v1`, the IP rate limit, `:agent_no_replay`, the `ip_banned` / `invalid_secret` / `joins_locked` codes |
| Threads and messages | `:agent`, Idempotency, the larger body limit |
| Event feed / watcher | `:feed`, `:sse` without `accepts` |
| Attachments | `[:sse, :agent]` download, `too_large` |
| MCP endpoint | `:mcp`, `Origin`, in-process dispatch skipping the IP limit |
| Admin UI | `:browser` + `:admin`, plain-text 429 |
| Metrics / health | `:sse` (`/metrics`), `:api` (`/healthz`) |
