defmodule C3Web.Plugs.RateLimit do
  @moduledoc """
  Per-minute request limits, `429 rate_limited` with `retry-after` once exceeded.

    * `plug RateLimit, :ip` — per client IP (`C3_RATE_LIMIT_IP`); needs `RealIp` first.
    * `plug RateLimit, :token` — per agent (`C3_RATE_LIMIT_TOKEN`); needs `AgentAuth` first.
  """
  @behaviour Plug

  import Plug.Conn

  alias C3.{Config, RateLimiter}
  alias C3Web.ApiError

  @impl true
  def init(scope) when scope in [:ip, :token], do: scope

  @impl true
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
        |> ApiError.send_error(429, "rate_limited", "Too many requests", %{
          retry_after: retry_after
        })
    end
  end
end
