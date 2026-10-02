defmodule C3Web.MCPHelpers do
  @moduledoc "Talking to `/mcp` from a test, the way a `2026-07-28` client does."
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint C3Web.Endpoint
  @version "2026-07-28"

  @doc "The `_meta` a modern client puts on every request."
  def meta(version \\ @version) do
    %{
      "io.modelcontextprotocol/protocolVersion" => version,
      "io.modelcontextprotocol/clientInfo" => %{"name" => "c3-test", "version" => "0"},
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  end

  @doc """
  Posts a JSON-RPC request with the headers the spec requires, unless `headers` overrides
  them (a `nil` value drops one).
  """
  def mcp(conn, method, params \\ %{}, headers \\ %{}) do
    params = Map.put_new(params, "_meta", meta())

    defaults = %{
      "content-type" => "application/json",
      "accept" => "application/json, text/event-stream",
      "mcp-protocol-version" => @version,
      "mcp-method" => method,
      "mcp-name" => params["name"]
    }

    defaults
    |> Map.merge(headers)
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> post(
      "/mcp",
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    )
  end

  @doc "Calls a tool and returns `{status, body}`: the REST status and body it carries."
  def tool(conn, name, args \\ %{}) do
    conn = mcp(conn, "tools/call", %{"name" => name, "arguments" => args})

    %{"result" => %{"isError" => error?, "structuredContent" => body} = result} =
      json_response(conn, 200)

    status = result["_meta"]["c3/status"]
    ^error? = status >= 400
    {status, body}
  end
end
