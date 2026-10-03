defmodule C3Web.V1.KnowledgeController do
  @moduledoc """
  The shared memory of a session (`C3.Knowledge`): record an entry, recall the entries,
  retract one. Entries are addressed by their readable id (`K3`) inside the agent's session.
  """
  use C3Web, :controller

  alias C3.Knowledge

  action_fallback C3Web.V1.FallbackController

  def index(conn, params) do
    with {:ok, entries} <- Knowledge.recall(conn.assigns.current_agent, params) do
      render(conn, :index, entries: entries)
    end
  end

  def create(conn, params) do
    with {:ok, entry} <- Knowledge.record(conn.assigns.current_agent, params) do
      conn |> put_status(:created) |> render(:show, entry: entry)
    end
  end

  def retract(conn, %{"entry" => ref} = params) do
    with {:ok, entry} <- Knowledge.retract(conn.assigns.current_agent, ref, params) do
      render(conn, :show, entry: entry)
    end
  end
end
