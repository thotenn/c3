defmodule C3Web.HealthControllerTest do
  use C3Web.ConnCase

  test "GET /healthz", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
