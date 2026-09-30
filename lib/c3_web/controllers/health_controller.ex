defmodule C3Web.HealthController do
  use C3Web, :controller

  @doc "Liveness + readiness: the app is up and the database answers."
  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(C3.Repo, "SELECT 1", []) do
      {:ok, _} ->
        json(conn, %{status: "ok"})

      {:error, _} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "error", db: "unavailable"})
    end
  end
end
