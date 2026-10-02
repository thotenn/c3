defmodule C3Web.AdminAuth do
  @moduledoc """
  The admin's browser login: the admin token, once, in exchange for a signed session
  cookie that holds the token's fingerprint (`C3.Admin.fingerprint/0`) and the login time,
  never the token. A login lasts `admin_session_ttl`, and rotating `C3_ADMIN_TOKEN` voids
  every login.

  `on_mount(:require_admin, …)` guards the admin LiveViews on the first render and on every
  (re)connection of their socket, and checks the login again before each event, so an
  action never runs on an expired one.
  """
  import Phoenix.Controller, only: [redirect: 2]
  import Plug.Conn

  alias C3.Admin

  @fingerprint "c3_admin"
  @at "c3_admin_at"

  @doc "Logs the admin in: a fresh session (no fixation) with the fingerprint and the time."
  def log_in(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(@fingerprint, Admin.fingerprint())
    |> put_session(@at, System.system_time(:second))
  end

  @doc "Logs the admin out: the whole session cookie goes."
  def log_out(conn), do: conn |> configure_session(drop: true)

  @doc "Whether the session map holds a valid login."
  def logged_in?(session), do: Admin.valid_login?(session[@fingerprint], session[@at])

  def on_mount(:require_admin, _params, session, socket) do
    if logged_in?(session) do
      socket =
        socket
        |> Phoenix.Component.assign(:admin_login_at, session[@at])
        |> Phoenix.LiveView.attach_hook(:admin_login, :handle_event, &check_login/3)

      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/admin/login")}
    end
  end

  defp check_login(_event, _params, socket) do
    if Admin.valid_login?(Admin.fingerprint(), socket.assigns.admin_login_at) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/admin/login")}
    end
  end

  @doc "Plug for a controller action that needs the login (none yet beyond the LiveViews)."
  def require_admin(conn, _opts) do
    if logged_in?(get_session(conn)),
      do: conn,
      else: conn |> redirect(to: "/admin/login") |> halt()
  end
end
