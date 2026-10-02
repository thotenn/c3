defmodule C3Web.V1.FallbackController do
  @moduledoc "Turns the `{:error, …}` results of the contexts into `C3Web.ApiError` responses."
  use C3Web, :controller

  alias C3Web.ApiError

  def call(conn, {:error, :ip_banned, until}) do
    ApiError.send_error(conn, 403, "ip_banned", "This IP cannot create or join sessions today", %{
      banned_until: until
    })
  end

  def call(conn, {:error, :invalid_secret}) do
    ApiError.send_error(conn, 403, "invalid_secret", "Wrong security number; this IP is banned")
  end

  def call(conn, {:error, :not_found}) do
    ApiError.send_error(conn, 404, "not_found", "No such session")
  end

  def call(conn, {:error, :session_closed}) do
    ApiError.send_error(conn, 410, "session_closed", "The session is closed")
  end

  def call(conn, {:error, :joins_locked}) do
    ApiError.send_error(conn, 423, "joins_locked", "The session does not accept new agents")
  end

  def call(conn, {:error, :thread_not_found}) do
    ApiError.send_error(conn, 404, "not_found", "No such thread in this session")
  end

  def call(conn, {:error, :attachment_not_found}) do
    ApiError.send_error(conn, 404, "not_found", "No such attachment in this session")
  end

  def call(conn, {:error, {:invalid, message, details}}) do
    ApiError.send_error(conn, 422, "invalid_request", message, details)
  end

  def call(conn, {:error, {:forbidden, message}}) do
    ApiError.send_error(conn, 403, "forbidden", message)
  end

  def call(conn, {:error, {:conflict, message, details}}) do
    ApiError.send_error(conn, 409, "conflict", message, details)
  end

  def call(conn, {:error, {:too_large, message}}) do
    ApiError.send_error(conn, 413, "too_large", message)
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors = Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
    ApiError.send_error(conn, 422, "invalid_request", "Invalid parameters", errors)
  end

  defp translate_error({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
