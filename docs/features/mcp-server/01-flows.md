---
doc: features/mcp-server/01-flows
repo: c3
kind: feature-flows
anchored_to: fcd0bd9
generated: 2026-10-02
---
# MCP Server — flows

`/mcp` serves the C3 REST API to MCP clients as JSON-RPC over request/response Streamable HTTP. There are four flows. They differ by the JSON-RPC message that arrives and by the protocol version the client speaks. **Modern** clients (`2026-07-28`) are stateless and their headers are checked against the body. **Legacy** clients (`2025-03-26` to `2025-11-25`) also get `initialize`, and no session is kept for them. Only a `tools/call` reaches the domain, and it does so by re-entering the router as a `/v1` request.

## Flow: an agent calls a `c3_*` tool

**Entry:** `POST /mcp`, JSON-RPC `tools/call`

1. **Trigger** — The client posts a single JSON-RPC 2.0 request. The router sends it through the `:mcp` pipeline: `Origin`, `RealIp`, and the per-IP `RateLimit`. · `lib/c3_web/router.ex:pipeline :mcp` → `lib/c3_web/controllers/mcp_controller.ex:post` → `lib/c3_web/mcp/server.ex:handle`
2. **Guard** — The version comes from the `MCP-Protocol-Version` header. With no header the client is treated as `2025-03-26`. A version that is not in `@supported` gets `400` with `-32022`, plus the supported list. For a modern client, `modern` requires these to match the body: `MCP-Protocol-Version` against `_meta["io.modelcontextprotocol/protocolVersion"]`, `Mcp-Method` against `method`, and `Mcp-Name` against `params.name`. `Mcp-Name` may be `=?base64?…?=` encoded. Any mismatch gets `400` with `-32020`. · `lib/c3_web/mcp/server.ex:match_header`, `lib/c3_web/mcp/server.ex:match_name`, `lib/c3_web/mcp/server.ex:decode_header`
3. **Logic** — `Tools.request` maps the tool name to its single REST route:
   - `token`, `session_code`, `thread`, `attachment_id` and `idempotency_key` are dropped from the body (`@not_body`). The tool's `query:` keys go to the query string. Whatever is left becomes the body, but only for `POST` routes.
   - `:code` is resolved from the token through `C3.Sessions.get_agent_by_token`. An unknown token or a missing path argument becomes the segment `-`, so the route answers `401`/`404` exactly as REST would.
   - Arguments are **not** validated against `inputSchema`.
   - An unknown name gets JSON-RPC `-32602`.

   · `lib/c3_web/mcp/tools.ex:request`, `lib/c3_web/mcp/tools.ex:session_code`, `lib/c3_web/mcp/tools.ex:segment`
4. **Persist / call** — `Dispatch.run` builds a fresh `Plug.Conn` and calls `C3Web.Router` in-process. The response is captured by an adapter that never touches a socket. The token goes in as `Authorization: Bearer`, and `idempotency_key` as `Idempotency-Key`. The conn keeps the outer `client_ip` and sets `private.c3_mcp: true`. That flag makes `RealIp` and the IP rate limit skip it, so one call is not counted twice. Everything after that (auth, the per-token limit, idempotency, controllers) is the normal `/v1` pipeline. · `lib/c3_web/mcp/dispatch.ex:run`, `lib/c3_web/mcp/dispatch.ex:Adapter`, `lib/c3_web/mcp/dispatch.ex:headers`, `lib/c3_web/plugs/real_ip.ex:call`, `lib/c3_web/plugs/rate_limit.ex:call`
5. **Notify** — The MCP layer emits nothing itself. Any event or broadcast comes from the REST controller that ran (see `event-feed`, `threads-and-requests`). If the dispatch raises, the error is logged and the call becomes a `500` `internal_error` tool result. · `lib/c3_web/mcp/server.ex:run`
6. **Respond / render** — The response is always HTTP `200`. The REST body is returned twice: as `structuredContent`, and as JSON text in `content`, prefixed `HTTP <status>` on error. `isError` is set when status ≥ 400, and the REST status is in `_meta["c3/status"]`. Modern responses also get `resultType: "complete"`. · `lib/c3_web/mcp/server.ex:tool_result`

**Touch this flow when:** you add or rename a tool, change a REST route or its parameters, add a query-only argument (add it to the tool's `query:` list), or change how C3 errors reach agents.

**Breaks when:**
- A new `/v1` route is added without a `@tools` entry. Nothing fails, but the route stays invisible to MCP.
- A new path-only argument is not listed in `@not_body`. It then leaks into the request body.
- A C3 error is surfaced as an HTTP status (especially `401`). The moduledoc warns this would push clients into an OAuth flow.
- The body is not a single JSON-RPC object, for example a batch. The client gets `400` with `-32600`.

## Flow: a client discovers the server and lists tools

**Entry:** `POST /mcp` with `server/discover`, `tools/list` or `ping`

1. **Trigger** — Same entry and version guard as above. · `lib/c3_web/mcp/server.ex:handle`
2. **Logic** — `server/discover` returns `supportedVersions`, the tools capability, `@instructions`, and `serverInfo` under `_meta`. `tools/list` returns `Tools.list()`. Both carry the `@cache` hint: a one-hour TTL with `cacheScope: "public"`. · `lib/c3_web/mcp/server.ex:call`, `lib/c3_web/mcp/tools.ex:list`
3. **Respond** — `200`. The `version` in `serverInfo` is the app's `vsn`. · `lib/c3_web/mcp/server.ex:server_info`

**Touch this flow when:** you edit tool descriptions or schemas, or the agent-facing `@instructions` text.

**Breaks when:** Clients may keep a stale tool list for up to an hour after a release, because of the `@cache` TTL. Schemas declare `additionalProperties: false`, so a client that enforces it rejects arguments that the server would otherwise forward.

## Flow: a legacy client initializes

**Entry:** `POST /mcp` with `initialize`

1. **Trigger** — `initialize` is handled before the version check, whatever header the client sends. · `lib/c3_web/mcp/server.ex:handle`
2. **Logic** — The server echoes the client's `protocolVersion` if it is in `@legacy`. Otherwise it answers `2025-11-25`, the head of `@legacy`, and never the modern version. No session id is issued: the agent's identity is the `token` argument of each tool. · `lib/c3_web/mcp/server.ex:initialize`
3. **Respond** — `200` with the tools capability, `serverInfo` and `@instructions`. In the legacy path, later calls to an unknown method get `200` with `-32601`, where a modern client gets `404`. · `lib/c3_web/mcp/server.ex:legacy`

**Touch this flow when:** you add or drop support for a protocol version (`@modern`, `@legacy`).

**Breaks when:** A client relies on an `Mcp-Session-Id` header: none is ever sent.

## Flow: notifications, responses and non-POST methods

**Entry:** `POST /mcp` with no `id`, or a JSON-RPC response · `GET /mcp` · `DELETE /mcp`

1. **Logic** — A message with no `id` (a notification) gets `202` with an empty body. So does a `result`/`error` message from a client, because C3 never sends requests to clients. · `lib/c3_web/mcp/server.ex:handle`
2. **Respond** — `GET` and `DELETE` get `405` with `Allow: POST`. There is no SSE stream and no session to delete. The `:mcp` pipeline has no `accepts` plug on purpose, so a legacy `GET` with `Accept: text/event-stream` gets `405` rather than `406`. · `lib/c3_web/controllers/mcp_controller.ex:not_allowed`, `lib/c3_web/router.ex:pipeline :mcp`

**Touch this flow when:** you add server-to-client messages or streaming. This flow would have to be redesigned for either.

## Shared state

- **Agent token and session lookup.** The `:code` segment of a route is resolved through `C3.Sessions.get_agent_by_token` (`lib/c3_web/mcp/tools.ex:session_code`), and the token is authorized by the `/v1` auth plug. Both are owned by `sessions-and-agents` and `join-security`.
- **Per-IP rate limit and client IP.** These are counted once in the outer `/mcp` request, and the inner dispatch is skipped through `private.c3_mcp` (`lib/c3_web/plugs/rate_limit.ex:call`, `lib/c3_web/plugs/real_ip.ex:call`). A wrong `c3_join_session` secret bans the IP that `/mcp` resolved (see `join-security`).
- **Excluded on purpose:** the long-poll wait, SSE and `/heartbeat` are not exposed (`lib/c3_web/mcp/tools.ex:@moduledoc`). `c3_events` always forces `wait=0` (`lib/c3_web/mcp/tools.ex:request`). Waking an agent belongs to `watcher-and-plugin`, and the feed itself to `event-feed`.
- **Attachments.** `c3_get_attachment` pins `format=json` through `fixed_query` (`lib/c3_web/mcp/tools.ex:c3_get_attachment`). The upload and size rules belong to `attachments`.
