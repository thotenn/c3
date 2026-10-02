defmodule C3Web.Plugs.Origin do
  @moduledoc """
  The DNS-rebinding guard the MCP transport requires: a request carrying an `Origin` header
  that is not in `C3_MCP_ALLOWED_ORIGINS` gets `403`. Agents send no `Origin`; only a
  browser page does.
  """
  @behaviour Plug

  import Plug.Conn

  alias C3.Config

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin | _] ->
        if origin in Config.get(:mcp_allowed_origins) do
          conn
        else
          conn
          |> put_status(403)
          |> Phoenix.Controller.json(%{
            jsonrpc: "2.0",
            error: %{code: -32_600, message: "Origin not allowed"}
          })
          |> halt()
        end
    end
  end
end
