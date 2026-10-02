---
doc: features/mcp-server/01-flows
repo: c3
kind: feature-flows
anchored_to: e99b2ae
generated: 2026-10-02
---
# MCP Server — flows

The MCP endpoint has four flows, and they differ by JSON-RPC method and by protocol generation. The **handshake** flows answer from constants and never touch the database: `initialize` covers legacy clients and `server/discover` covers `2026-07-28`. **`tools/list`** returns the static tool catalogue. **`tools/call`** is the only flow that does real work: it turns a tool call into a `/v1` REST request and runs that request in-process through the router. Every message arrives as `POST /mcp`. `GET` and `DELETE` are refused.

## Flow: an agent connects (handshake)

**Entry:** `POST /mcp` with method `initialize` (legacy) or `server/discover` (`2026-07-28`)

1. **Trigger** — the client posts one JSON-RPC message · `lib/c3_web/controllers/mcp_controller.ex:post`
2. **Guard** — the router's `:mcp` pipeline runs `Origin`, `RealIp` and `RateLimit, :ip`. It has no `accepts`, so a legacy `GET` with `Accept: text/event-stream` gets `405` from `lib/c3_web/controllers/mcp_controller.ex:not_allowed` and not `406` · `lib/c3_web/router.ex:pipeline :mcp`
3. **Logic** — a message with no `id` is a notification and gets `202` with an empty body. `initialize` is handled before any version check. Every other method is routed by the `mcp-protocol-version` header, and a missing header is read as `2025-03-26` · `lib/c3_web/mcp/server.ex:handle`, `lib/c3_web/mcp/server.ex:version`
4. **Respond** — `initialize` echoes the requested version when it is in `@legacy`. Otherwise it returns `2025-11-25`, the first entry of `@legacy`, and **never** `@modern`. `server/discover` returns `supportedVersions`, `instructions` and the `@cache` hints (`ttlMs`, `cacheScope: public`) · `lib/c3_web/mcp/server.ex:initialize`, `lib/c3_web/mcp/server.ex:call`
5. **Respond (unsupported)** — an unknown version gets `400` with `-32022` (`@unsupported_version`), and `data` lists both the supported and the requested versions · `lib/c3_web/mcp/server.ex:unsupported`

No session is created and no `Mcp-Session-Id` is issued. The agent's identity is the `token` argument of each tool.

**Touch this flow when:** you add support for a new MCP protocol version, change the server `instructions` text (`lib/c3_web/mcp/server.ex:@instructions`), or change capabilities.
**Breaks when:** a browser-originated request carries an `Origin` header that is not in the allowed-origins config. `lib/c3_web/plugs/origin.ex` then returns `403` before the server sees the request. Agents send no `Origin`.

## Flow: modern request validation (`2026-07-28`)

**Entry:** any non-`initialize` method sent with `MCP-Protocol-Version: 2026-07-28`

1. **Guard** — the header must equal `params._meta["io.modelcontextprotocol/protocolVersion"]` · `lib/c3_web/mcp/server.ex:match_header`
2. **Guard** — the `Mcp-Method` header must equal the body's `method` · `lib/c3_web/mcp/server.ex:match_header`
3. **Guard** — for `tools/call`, `resources/read` and `prompts/get`, the `Mcp-Name` header must equal `params.name` or `params.uri`. The header may use the `=?base64?…?=` encoding. If it is malformed, the raw value is compared instead · `lib/c3_web/mcp/server.ex:match_name`, `lib/c3_web/mcp/server.ex:decode_header`
4. **Respond** — any mismatch gets `400` with `-32020`. Success adds `resultType: "complete"`. An unknown method gets **HTTP `404`** with `-32601` · `lib/c3_web/mcp/server.ex:modern`

The two generations handle errors differently. `lib/c3_web/mcp/server.ex:legacy` skips the header checks, does not add `resultType`, and returns an unknown method as `200` with `-32601`, not `404`.

**Touch this flow when:** the MCP spec changes header semantics, or a client reports `Header mismatch`.
**Breaks when:** a client sends the modern version header but leaves `_meta.protocolVersion` out of the body. The comparison is against `nil`, so the request is rejected.

## Flow: list the tools

**Entry:** method `tools/list`

1. **Logic** — `C3Web.MCP.Tools.list/0` maps the `@tools` registry in its declared order. Each schema sets `additionalProperties: false` · `lib/c3_web/mcp/tools.ex:list`
2. **Respond** — the tool list merged with the `@cache` hints, so clients may cache it for an hour · `lib/c3_web/mcp/server.ex:call`

**Touch this flow when:** you add, rename or re-describe a `c3_*` tool. The descriptions are the agent-facing documentation and must stay in step with `docs/mcp.md`.
**Breaks when:** a tool's `required` lists a key that is missing from its `properties`. Nothing in the code catches this, and clients reject the schema.

## Flow: an agent calls a tool

**Entry:** method `tools/call`, e.g. `c3_post`

1. **Trigger** — `call` requires `name` to be a binary and `arguments` to be a map. If `arguments` is missing, it is replaced with `%{}`. Any other shape gets `-32602` · `lib/c3_web/mcp/server.ex:call`
2. **Logic** — `Tools.request/2` finds the tool in `@by_name` and builds a REST request:
   - The keys in `@not_body` are taken out of the body: `token`, `session_code`, `thread`, `attachment_id` and `idempotency_key`.
   - Keys listed in a tool's `:query` go to the query string. `:fixed_query` is merged in (`format=json` for `c3_get_attachment`), and `wait=0` is forced on the events route.
   - Only `:post` routes send a body.

   An unknown tool name gets `-32602` (`Unknown tool`) · `lib/c3_web/mcp/tools.ex:request`
3. **Logic (path)** — `:code` comes from `session_code` or, failing that, from the token's agent row. That is a database read (`C3.Sessions.get_agent_by_token`) **made before** auth runs. An unknown or missing value becomes the segment `-`, so the real route returns the REST `401` or `404` · `lib/c3_web/mcp/tools.ex:path`, `lib/c3_web/mcp/tools.ex:session_code`, `lib/c3_web/mcp/tools.ex:segment`
4. **Persist / call** — `Dispatch.run/2` builds a `%Plug.Conn{}` around a no-socket `Adapter` and calls `C3Web.Router` directly:
   - The token is sent as a `Bearer` header and the idempotency key as `Idempotency-Key`. The user agent and `client_ip` come from the `/mcp` connection.
   - It sets `private.c3_mcp: true`, so `RealIp` and the per-IP `RateLimit` are skipped: the call was already counted once at `/mcp`.
   - The endpoint plugs are bypassed, so no body parsing happens. The `Adapter` raises on `send_file` and `send_chunked`, which means only JSON routes can be tools.

   Auth, per-token limits, idempotency and the controllers all behave exactly as they do for REST · `lib/c3_web/mcp/dispatch.ex:run`, `lib/c3_web/mcp/dispatch.ex:headers`, `lib/c3_web/plugs/rate_limit.ex:call`
5. **Notify** — whatever the dispatched controller broadcasts. This feature emits nothing of its own (see `event-feed`).
6. **Respond** — `tool_result/2` wraps the REST status and body:
   - The body is sent twice: as `structuredContent` and as JSON text. An error's text gets an `HTTP <status>` prefix.
   - `isError` is true when the status is 400 or higher.
   - `_meta["c3/status"]` carries the REST status.

   **A REST `401` is still a JSON-RPC `200`**, because an HTTP 401 would push the client into OAuth. A crash in the dispatched request is logged, then returned as an `isError` result with status `500` and code `internal_error` · `lib/c3_web/mcp/server.ex:run`, `lib/c3_web/mcp/server.ex:tool_result`

**Touch this flow when:** a REST route a tool maps to changes its path or parameters, or you need a new tool for a new `/v1` route. Add an entry to `@tools` in `lib/c3_web/mcp/tools.ex`, and if the new path segment is not `:code`, `:thread` or `:attachment`, extend `path/2`.
**Breaks when:**
- A new tool argument that belongs in the path or a header is not added to `@not_body`. It then leaks into the POST body.
- A route returns a non-JSON body, so `Jason.decode!` in `Dispatch.run` raises.
- A tool's arguments are not checked against its schema here, so a mistake shows up as the REST `422` or `401`, not as an MCP `-32602`.

## Not exposed as tools

The SSE stream, the long-poll wait and `/heartbeat` have no tools, as stated in the moduledoc of `lib/c3_web/mcp/tools.ex`. Waking an agent is the watcher's job (`watcher-and-plugin`), and every tool call already counts as activity. `c3_events` always calls the events route with `wait=0`.

## Shared state

- **Agent tokens and session lookup:** `C3.Sessions` (`sessions-and-agents`), read directly by `lib/c3_web/mcp/tools.ex:session_code`.
- **Per-IP and per-token rate limits and bans:** `lib/c3_web/plugs/rate_limit.ex` (`join-security`). An MCP call counts once per IP, at `/mcp`.
- **Idempotency replay, auth and the REST error bodies:** the `/v1` pipeline that every tool call goes through (`threads-and-requests`, `sessions-and-agents`, `attachments`).
- **Allowed origins:** `lib/c3_web/plugs/origin.ex`, configured as `C3_MCP_ALLOWED_ORIGINS`.
