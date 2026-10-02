defmodule C3Web.PageControllerTest do
  use C3Web.ConnCase

  test "GET / says what C3 is, with no Phoenix boilerplate", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Central Context Coordinator"
    assert html =~ ~s(id="home-docs")
    refute html =~ "Phoenix Framework"
    refute html =~ "phoenixframework.org"
  end
end
