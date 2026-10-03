defmodule C3Web.V1.SearchController do
  @moduledoc "`GET /v1/sessions/{code}/search`: text search over the session's messages (`C3.Search`)."
  use C3Web, :controller

  alias C3.Search

  action_fallback C3Web.V1.FallbackController

  def index(conn, params) do
    with {:ok, messages, terms} <- Search.messages(conn.assigns.current_agent, params) do
      render(conn, :index, messages: messages, terms: terms)
    end
  end
end
