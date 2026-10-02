defmodule C3Web.PageController do
  use C3Web, :controller

  def home(conn, _params) do
    conn
    |> assign(:page_title, "Central Context Coordinator")
    |> render(:home)
  end
end
