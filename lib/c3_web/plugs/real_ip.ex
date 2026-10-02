defmodule C3Web.Plugs.RealIp do
  @moduledoc """
  Puts the client IP, as a string, in `conn.assigns.client_ip`.

  With `C3_REAL_IP_HEADER` unset it is the peer address. With it set (`x-forwarded-for`,
  `x-real-ip`, …) the header is honored only when the peer is a trusted proxy
  (`C3_TRUSTED_PROXIES`); its comma-separated list is read from the right, skipping trusted
  proxies, so a client cannot spoof its address by prepending entries.

  A request the MCP endpoint dispatches in-process (`C3Web.MCP.Dispatch`) keeps the address
  `/mcp` already resolved.
  """
  @behaviour Plug

  import Plug.Conn

  alias C3.Config
  alias C3.Security.CIDR

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{private: %{c3_mcp: true}} = conn, _opts), do: conn
  def call(conn, _opts), do: assign(conn, :client_ip, client_ip(conn))

  defp client_ip(conn) do
    peer = conn.remote_ip
    header = Config.get(:real_ip_header)
    trusted = Config.get(:trusted_proxies)

    forwarded =
      if header && CIDR.member?(peer, trusted) do
        conn
        |> get_req_header(header)
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&CIDR.parse_ip/1)
        |> Enum.flat_map(fn
          {:ok, ip} -> [ip]
          :error -> []
        end)
      else
        []
      end

    ip =
      forwarded
      |> Enum.reverse()
      |> Enum.find(List.first(forwarded) || peer, &(not CIDR.member?(&1, trusted)))

    CIDR.to_string(ip)
  end
end
