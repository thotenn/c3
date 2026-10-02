defmodule C3Web.MCPController do
  @moduledoc """
  `/mcp`, the remote MCP endpoint (spec, *Integración con los agentes*): every JSON-RPC
  message is a `POST`, answered with a single JSON object (`C3Web.MCP.Server`). There is no
  `GET` stream nor session to `DELETE` in the protocol C3 serves: both are `405`.
  """
  use C3Web, :controller

  alias C3Web.MCP.Server

  def post(conn, _params) do
    case Server.handle(conn, conn.body_params) do
      {status, nil} -> send_resp(conn, status, "")
      {status, response} -> conn |> put_status(status) |> json(response)
    end
  end

  def not_allowed(conn, _params) do
    conn |> put_resp_header("allow", "POST") |> send_resp(405, "")
  end
end
