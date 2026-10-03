defmodule C3Web.V1.SessionController do
  @moduledoc """
  `/v1/sessions`: create, join, show, start, leave, close, unlock and rotate the secret (spec,
  *API › Sesión*). `start` — and a join with `start: true` — answers in one call what an agent
  reads when it begins or resumes: the session, its inbox, the active shared memory and the
  active reservations.
  """
  use C3Web, :controller

  alias C3.{Knowledge, Reservations, Sessions, Threads}
  alias C3Web.V1.InboxController

  action_fallback C3Web.V1.FallbackController

  def create(conn, params) do
    with {:ok, created} <- Sessions.create_session(params, meta(conn)) do
      conn |> put_status(:created) |> render(:created, created)
    end
  end

  def join(conn, %{"code" => code} = params) do
    with {:ok, joined} <- Sessions.join_session(code, params, meta(conn)) do
      joined =
        if params["start"] in [true, "true"],
          do: Map.put(joined, :start, start_assigns(joined.session, joined.agent)),
          else: joined

      conn |> put_status(:created) |> render(:joined, joined)
    end
  end

  def show(conn, _params) do
    %{current_session: session, current_agent: agent} = conn.assigns
    render(conn, :show, show_assigns(session, agent))
  end

  def start(conn, _params) do
    %{current_session: session, current_agent: agent} = conn.assigns
    render(conn, :start, start_assigns(session, agent))
  end

  def leave(conn, _params) do
    with {:ok, released} <- Sessions.leave(conn.assigns.current_agent) do
      json(conn, %{left: true, released: released})
    end
  end

  def close(conn, _params) do
    with {:ok, session} <- Sessions.close(conn.assigns.current_agent) do
      json(conn, %{
        status: session.status,
        closed_at: session.closed_at,
        closed_by: session.closed_by
      })
    end
  end

  def unlock(conn, _params) do
    with {:ok, unlocked?} <- Sessions.unlock_joins(conn.assigns.current_agent) do
      json(conn, %{joins_locked: false, unlocked: unlocked?})
    end
  end

  def rotate_secret(conn, _params) do
    with {:ok, %{secret: secret, unlocked: unlocked?}} <-
           Sessions.rotate_secret(conn.assigns.current_agent) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{secret: secret, joins_locked: false, unlocked: unlocked?})
    end
  end

  defp show_assigns(session, agent) do
    %{
      session: session,
      you: agent,
      agents: Sessions.list_agents(session),
      threads: Threads.list_threads(session, preload: :opened_by_agent)
    }
  end

  # Reading the inbox marks its cancellations and alerts seen, as `GET /v1/inbox` does.
  defp start_assigns(session, agent) do
    {:ok, knowledge} = Knowledge.recall(agent)
    {:ok, reservations} = Reservations.list(agent)

    %{
      show: show_assigns(session, agent),
      inbox: InboxController.inbox(agent),
      knowledge: knowledge,
      reservations: reservations
    }
  end

  defp meta(conn) do
    %{
      ip: conn.assigns.client_ip,
      user_agent: conn |> get_req_header("user-agent") |> List.first()
    }
  end
end
