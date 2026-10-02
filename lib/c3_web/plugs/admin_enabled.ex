defmodule C3Web.Plugs.AdminEnabled do
  @moduledoc """
  Answers `404` on every `/admin` route while `C3_ADMIN_TOKEN` is unset: without a token
  there is no admin, not even a login page to probe.
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if C3.Admin.enabled?() do
      conn
    else
      conn
      |> put_status(404)
      |> put_view(html: C3Web.ErrorHTML)
      |> render(:"404")
      |> halt()
    end
  end
end
