defmodule C3Web.MCP.Dispatch do
  @moduledoc """
  Runs the REST request of a tool call (`C3Web.MCP.Tools.request/2`) in-process, through
  `C3Web.Router`, and returns `{status, body}`. The tool goes through the very pipeline a
  REST client does — `AgentAuth` (ban-proof tokens, `410`, activity), the per-token rate
  limit, `Idempotency`, the controllers, `FallbackController` and the JSON views — so MCP
  and REST cannot drift apart.

  The request keeps the client IP `/mcp` resolved and skips the per-IP limit, already
  counted there (`private.c3_mcp`). It skips the endpoint plugs: the body is already a map.
  """
  alias C3Web.Router

  defmodule Adapter do
    @moduledoc false
    # Keeps the response on the conn instead of writing it to a socket.
    @behaviour Plug.Conn.Adapter

    @impl true
    def send_resp(state, _status, _headers, body), do: {:ok, body, state}
    @impl true
    def send_file(_state, _status, _headers, _path, _offset, _length), do: raise("not supported")
    @impl true
    def send_chunked(_state, _status, _headers), do: raise("not supported")
    @impl true
    def chunk(_state, _body), do: {:error, :not_supported}
    @impl true
    def read_req_body(state, _opts), do: {:ok, "", state}
    @impl true
    def push(_state, _path, _headers), do: {:error, :not_supported}
    @impl true
    def inform(_state, _status, _headers), do: {:error, :not_supported}
    @impl true
    def upgrade(_state, _protocol, _opts), do: {:error, :not_supported}
    @impl true
    def get_peer_data(%{peer: peer}), do: peer
    @impl true
    def get_sock_data(%{sock: sock}), do: sock
    @impl true
    def get_ssl_data(_state), do: nil
    @impl true
    def get_http_protocol(_state), do: :"HTTP/1.1"
  end

  @router_opts Router.init([])

  @doc "Runs `request` on behalf of the `/mcp` connection `outer`."
  def run(%Plug.Conn{} = outer, request) do
    query_string = URI.encode_query(request.query)
    query_params = URI.decode_query(query_string)

    conn = %Plug.Conn{
      adapter:
        {Adapter, %{peer: Plug.Conn.get_peer_data(outer), sock: Plug.Conn.get_sock_data(outer)}},
      owner: self(),
      method: request.method,
      host: outer.host,
      port: outer.port,
      scheme: outer.scheme,
      remote_ip: outer.remote_ip,
      request_path: request.path,
      path_info: String.split(request.path, "/", trim: true),
      query_string: query_string,
      query_params: query_params,
      body_params: request.body,
      params: Map.merge(query_params, request.body),
      req_headers: headers(outer, request),
      assigns: %{client_ip: outer.assigns.client_ip},
      private: %{c3_mcp: true}
    }

    conn = Router.call(conn, @router_opts)
    {conn.status, Jason.decode!(IO.iodata_to_binary(conn.resp_body))}
  end

  defp headers(outer, request) do
    [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"authorization", request.token && "Bearer " <> request.token},
      {"idempotency-key", request.idempotency_key},
      {"user-agent", outer |> Plug.Conn.get_req_header("user-agent") |> List.first()}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end
end
