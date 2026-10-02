defmodule C3Web.AdminSessionController do
  @moduledoc """
  The admin's login and logout (`C3Web.AdminAuth`). A wrong token is a `401` and a warning
  in the log; the login is held to `@login_limit` tries per minute and IP, on top of the IP
  limit of every `/admin` route.
  """
  use C3Web, :controller

  require Logger

  alias C3.{Admin, RateLimiter}
  alias C3Web.AdminAuth

  @login_limit 10

  def new(conn, _params) do
    if AdminAuth.logged_in?(get_session(conn)),
      do: redirect(conn, to: ~p"/admin"),
      else: render(conn, :new, form: login_form())
  end

  def create(conn, %{"login" => %{"token" => token}}) do
    ip = conn.assigns.client_ip

    case RateLimiter.hit({:admin_login, ip}, @login_limit, 60_000) do
      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(429)
        |> put_flash(:error, "Too many attempts. Try again in #{retry_after} s.")
        |> render(:new, form: login_form())

      :ok ->
        if Admin.valid_token?(String.trim(token)) do
          Logger.info("Admin login from #{ip}")

          conn
          |> AdminAuth.log_in()
          |> redirect(to: ~p"/admin")
        else
          Logger.warning("Failed admin login from #{ip}")

          conn
          |> put_status(401)
          |> put_flash(:error, "Invalid admin token.")
          |> render(:new, form: login_form())
        end
    end
  end

  def create(conn, _params), do: create(conn, %{"login" => %{"token" => ""}})

  def delete(conn, _params) do
    conn
    |> AdminAuth.log_out()
    |> redirect(to: ~p"/admin/login")
  end

  defp login_form, do: Phoenix.Component.to_form(%{"token" => ""}, as: :login)
end
