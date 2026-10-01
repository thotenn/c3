defmodule C3Web.Plugs.Idempotency do
  @moduledoc """
  Honors `Idempotency-Key` on the agents' `POST`s (`C3.Idempotency`); needs `AgentAuth` first.

    * No header: the request runs as usual.
    * A key never seen: the request runs and its response is stored, unless it is a `5xx`
      (a server failure is worth retrying for real).
    * The same key with the same method, path and body: the stored response is replayed,
      with `idempotent-replayed: true`.
    * The same key with another request: `422 invalid_request`.
    * The same key while its first request is still running: `409 conflict`.
  """
  @behaviour Plug

  import Plug.Conn

  alias C3.Idempotency
  alias C3Web.ApiError

  @max_key 100

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    case get_req_header(conn, "idempotency-key") do
      [] -> conn
      [key | _] -> handle(conn, String.trim(key))
    end
  end

  def call(conn, _opts), do: conn

  defp handle(conn, key) when key == "" or byte_size(key) > @max_key do
    ApiError.send_error(
      conn,
      400,
      "invalid_request",
      "Idempotency-Key must be 1 to #{@max_key} characters"
    )
  end

  defp handle(conn, key) do
    agent = conn.assigns.current_agent
    hash = request_hash(conn)

    case Idempotency.lookup(agent, key) do
      %{request_hash: ^hash} = stored ->
        conn
        |> put_resp_header("idempotent-replayed", "true")
        |> put_status(stored.response_status)
        |> Phoenix.Controller.json(stored.response_body)
        |> halt()

      %{} ->
        ApiError.send_error(
          conn,
          422,
          "invalid_request",
          "This Idempotency-Key was already used for a different request"
        )

      nil ->
        run(conn, agent, key, hash)
    end
  end

  defp run(conn, agent, key, hash) do
    case Idempotency.begin(agent, key) do
      :ok ->
        register_before_send(conn, fn conn ->
          if conn.status < 500, do: store(agent, key, hash, conn)
          Idempotency.finish(agent, key)
          conn
        end)

      :busy ->
        ApiError.send_error(
          conn,
          409,
          "conflict",
          "A request with this Idempotency-Key is still running"
        )
    end
  end

  defp store(agent, key, hash, conn) do
    case Jason.decode(IO.iodata_to_binary(conn.resp_body || "")) do
      {:ok, %{} = body} -> Idempotency.store(agent, key, hash, conn.status, body)
      _ -> :ok
    end
  end

  # Method + path + query + the parsed body, in a deterministic encoding: the same JSON with
  # its keys in another order is the same request.
  defp request_hash(conn) do
    data = {conn.method, conn.request_path, conn.query_string, conn.body_params}

    :crypto.hash(:sha256, :erlang.term_to_binary(data, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
