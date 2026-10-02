defmodule C3Web.MetricsController do
  @moduledoc """
  `GET /metrics`: `C3.Metrics` in the Prometheus text format, for a scraper holding
  `C3_METRICS_TOKEN` as a bearer token. Without the variable the route does not exist
  (`404`), like `/admin` without `C3_ADMIN_TOKEN`; a missing or wrong token is a `401`.
  """
  use C3Web, :controller

  alias C3Web.ApiError

  def show(conn, _params) do
    case C3.Config.get(:metrics_token) do
      nil ->
        ApiError.send_error(conn, 404, "not_found", "Not found")

      token ->
        if authorized?(conn, token) do
          conn
          |> put_resp_content_type("text/plain; version=0.0.4", "utf-8")
          |> put_resp_header("cache-control", "no-store")
          |> send_resp(200, C3.Metrics.prometheus())
        else
          conn
          |> put_resp_header("www-authenticate", ~s(Bearer realm="c3-metrics"))
          |> ApiError.send_error(401, "unauthorized", "A valid metrics token is required")
        end
    end
  end

  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> given | _] -> Plug.Crypto.secure_compare(String.trim(given), token)
      _ -> false
    end
  end
end
