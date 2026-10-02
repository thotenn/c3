defmodule C3Web.Plugs.RateLimit do
  @moduledoc """
  Per-minute request limits, `429 rate_limited` with `retry-after` once exceeded (plain
  text on the admin pages).

    * `plug RateLimit, :ip` — per client IP (`C3_RATE_LIMIT_IP`); needs `RealIp` first.
    * `plug RateLimit, :token` — per agent (`C3_RATE_LIMIT_TOKEN`); needs `AgentAuth` first.

  A tool call of the MCP endpoint counts once per IP, at `/mcp`: the REST request it is
  dispatched as (`C3Web.MCP.Dispatch`) skips the IP limit and counts only per token.
  """
  @behaviour Plug

  import Plug.Conn

  alias C3.{Config, RateLimiter}
  alias C3Web.ApiError

  @impl true
  def init(scope) when scope in [:ip, :token], do: scope

  @impl true
  def call(%Plug.Conn{private: %{c3_mcp: true}} = conn, :ip), do: conn
  def call(conn, :ip), do: limit(conn, {:ip, conn.assigns.client_ip}, Config.get(:rate_limit_ip))

  def call(conn, :token) do
    limit(conn, {:token, conn.assigns.current_agent.token_hash}, Config.get(:rate_limit_token))
  end

  defp limit(conn, key, limit) do
    case RateLimiter.hit(key, limit, Config.get(:rate_limit_window_ms)) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> reject(retry_after)
    end
  end

  # The admin pages are a browser's: plain text, not the JSON error of the API.
  defp reject(%Plug.Conn{path_info: ["admin" | _]} = conn, retry_after) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(429, "Too many requests. Try again in #{retry_after} s.")
    |> halt()
  end

  defp reject(conn, retry_after) do
    ApiError.send_error(conn, 429, "rate_limited", "Too many requests", %{
      retry_after: retry_after
    })
  end
end
