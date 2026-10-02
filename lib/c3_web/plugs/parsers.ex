defmodule C3Web.Plugs.Parsers do
  @moduledoc """
  `Plug.Parsers` with two body limits: 1 MB everywhere, and
  `C3.Config.attachments_request_max_bytes/0` on the routes that can carry attachments
  inline — opening a thread, posting to one, and `/mcp` (whose tool calls post too). Over
  the limit is a `413 too_large`. The per-file, per-post and per-session limits are then
  checked by `C3.Attachments`.
  """
  @behaviour Plug

  @default_length 1_048_576

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    length =
      if carries_attachments?(conn),
        do: C3.Config.attachments_request_max_bytes(),
        else: @default_length

    Plug.Parsers.call(conn, Plug.Parsers.init(Keyword.put(opts, :length, length)))
  end

  defp carries_attachments?(%Plug.Conn{method: "POST", path_info: path}) do
    match?(["v1", "threads", _, "messages"], path) or
      match?(["v1", "sessions", _, "threads"], path) or
      path == ["mcp"]
  end

  defp carries_attachments?(_conn), do: false
end
