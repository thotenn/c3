defmodule C3Web.V1.ReservationController do
  @moduledoc """
  Advisory reservations of a session (`C3.Reservations`): list, reserve, renew and release.
  Renew and release act on the caller's own reservations — the ids given, or all of them.
  """
  use C3Web, :controller

  alias C3.Reservations

  action_fallback C3Web.V1.FallbackController

  def index(conn, params) do
    with {:ok, reservations} <- Reservations.list(conn.assigns.current_agent, params) do
      render(conn, :index, reservations: reservations)
    end
  end

  def create(conn, params) do
    with {:ok, reservations} <- Reservations.reserve(conn.assigns.current_agent, params) do
      conn |> put_status(:created) |> render(:index, reservations: reservations)
    end
  end

  def renew(conn, params) do
    with {:ok, reservations} <- Reservations.renew(conn.assigns.current_agent, params) do
      render(conn, :index, reservations: reservations)
    end
  end

  def release(conn, params) do
    with {:ok, reservations} <- Reservations.release(conn.assigns.current_agent, params) do
      render(conn, :index, reservations: reservations)
    end
  end
end
