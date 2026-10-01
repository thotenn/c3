defmodule C3Web.ErrorJSONTest do
  use C3Web.ConnCase, async: true

  test "renders 404 with the stable error shape" do
    assert C3Web.ErrorJSON.render("404.json", %{}) ==
             %{error: %{code: "not_found", message: "Not Found"}}
  end

  test "renders 500" do
    assert C3Web.ErrorJSON.render("500.json", %{}) ==
             %{error: %{code: "internal_error", message: "Internal Server Error"}}
  end

  test "an unknown /v1 route answers with the same shape", %{conn: conn} do
    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> put_req_header("accept", "application/json")
             |> get("/v1/nope")
             |> json_response(404)
  end
end
