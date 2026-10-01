defmodule C3Web.ErrorJSON do
  @moduledoc """
  Renders the errors Phoenix raises on JSON requests (no route, a body that does not parse,
  a crash) with the API's stable shape, `C3Web.ApiError`.
  """
  alias C3Web.ApiError

  @codes %{
    "400" => "invalid_request",
    "401" => "unauthorized",
    "403" => "forbidden",
    "404" => "not_found",
    "409" => "conflict",
    "410" => "session_closed",
    "413" => "too_large",
    "415" => "invalid_request",
    "422" => "invalid_request",
    "429" => "rate_limited"
  }

  def render(template, _assigns) do
    status = template |> String.split(".") |> hd()
    code = Map.get(@codes, status, "internal_error")
    ApiError.body(code, Phoenix.Controller.status_message_from_template(template))
  end
end
