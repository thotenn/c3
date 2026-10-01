defmodule C3Web.Plugs.AgentAuth do
  @moduledoc """
  Authenticates an agent by `Authorization: Bearer <token>`, and assigns `current_agent` and
  `current_session`. On a route with `:code` the token must belong to that session; on the
  others (`/threads/:id`, `/inbox`) the token itself says which session it is.

  Order of the checks: no or unknown token → `401`; a token of another session than `:code`
  → `403`; a closed session → `410` (also for the tokens its close revoked); an agent that
  left → `401`. The IP ban is not checked here: a live token works from a banned IP.

  Every authenticated request counts as a sign of life (`Sessions.touch_seen/2`, throttled):
  it is what keeps the agent's claims from expiring. It also counts as activity on the
  session (`Sessions.touch_activity/2`, which postpones the idle close) unless the plug is
  given `activity: false` — the event feed and `/heartbeat`, so a watcher left running does
  not keep a forgotten session open until its max TTL.
  """
  @behaviour Plug

  import Plug.Conn

  alias C3.{Credentials, Sessions}
  alias C3Web.ApiError

  @impl true
  def init(opts), do: Keyword.validate!(opts, activity: true)

  @impl true
  def call(conn, opts) do
    with {:ok, token} <- bearer(conn),
         %Sessions.Agent{session: session} = agent <- Sessions.get_agent_by_token(token) do
      cond do
        not same_session?(conn.path_params["code"], session.code) ->
          ApiError.send_error(conn, 403, "forbidden", "The token belongs to another session")

        session.status == :closed ->
          ApiError.send_error(conn, 410, "session_closed", "The session is closed")

        agent.status != :active ->
          ApiError.send_error(conn, 401, "unauthorized", "The token was revoked")

        true ->
          now = DateTime.utc_now()
          agent = Sessions.touch_seen(agent, now)
          session = if opts[:activity], do: Sessions.touch_activity(session, now), else: session
          conn |> assign(:current_agent, agent) |> assign(:current_session, session)
      end
    else
      _ -> ApiError.send_error(conn, 401, "unauthorized", "Missing or invalid bearer token")
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp same_session?(nil, _session_code), do: true

  defp same_session?(code, session_code) do
    Credentials.normalize_code(code) == {:ok, session_code}
  end
end
