defmodule C3Web.Plugs.AgentAuth do
  @moduledoc """
  Authenticates an agent by `Authorization: Bearer <token>` for the routes of session
  `:code`, and assigns `current_agent` and `current_session`.

  Order of the checks: no or unknown token → `401`; a token of another session → `403`; a
  closed session → `410` (also for the tokens its close revoked); an agent that left → `401`.
  The IP ban is not checked here: a live token works from a banned IP.
  """
  @behaviour Plug

  import Plug.Conn

  alias C3.{Credentials, Sessions}
  alias C3Web.ApiError

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
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

  defp same_session?(code, session_code) do
    Credentials.normalize_code(code || "") == {:ok, session_code}
  end
end
