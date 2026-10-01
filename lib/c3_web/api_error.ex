defmodule C3Web.ApiError do
  @moduledoc """
  The stable error shape of the API: `{"error": {"code", "message", "details"?}}`.

  | Code | Status |
  |---|---|
  | `invalid_request` | 400 / 422 |
  | `unauthorized` | 401 |
  | `invalid_secret`, `ip_banned`, `forbidden` | 403 |
  | `not_found` | 404 |
  | `conflict` | 409 |
  | `session_closed` | 410 |
  | `too_large` | 413 |
  | `joins_locked` | 423 |
  | `rate_limited` | 429 |
  | `internal_error` | 500 |
  """
  import Plug.Conn

  @doc "The error body."
  def body(code, message, details \\ nil) do
    error = %{code: code, message: message}
    %{error: if(details, do: Map.put(error, :details, details), else: error)}
  end

  @doc "Sends the error and halts the connection."
  def send_error(conn, status, code, message, details \\ nil) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(body(code, message, details))
    |> halt()
  end
end
