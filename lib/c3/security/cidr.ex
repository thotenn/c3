defmodule C3.Security.CIDR do
  @moduledoc """
  IPv4/IPv6 CIDR blocks, for the trusted proxies and the ban allowlist. An IPv4-mapped IPv6
  address (`::ffff:a.b.c.d`) matches as its IPv4 form.
  """
  import Bitwise

  @type t :: {4 | 6, non_neg_integer(), non_neg_integer()}

  @doc "Parses `addr/bits` (or a bare address, a single host). Raises on an invalid block."
  def parse!(cidr) do
    case parse(cidr) do
      {:ok, block} -> block
      :error -> raise ArgumentError, "invalid CIDR block: #{inspect(cidr)}"
    end
  end

  def parse(cidr) when is_binary(cidr) do
    {addr, bits} =
      case String.split(String.trim(cidr), "/", parts: 2) do
        [addr, bits] -> {addr, Integer.parse(bits)}
        [addr] -> {addr, :host}
      end

    with {:ok, ip} <- parse_ip(addr),
         {family, n} = to_int(ip),
         size = size(family),
         {:ok, bits} <- prefix(bits, size) do
      mask = mask(bits, size)
      {:ok, {family, n &&& mask, mask}}
    else
      _ -> :error
    end
  end

  @doc "Parses an IP address string into a tuple; IPv4-mapped IPv6 becomes IPv4."
  def parse_ip(addr) when is_binary(addr) do
    case :inet.parse_strict_address(String.to_charlist(String.trim(addr))) do
      {:ok, ip} -> {:ok, unmap(ip)}
      {:error, _} -> :error
    end
  end

  @doc "Whether the IP tuple or string falls in any of the `cidrs` (strings)."
  def member?(ip, cidrs) when is_binary(ip) do
    case parse_ip(ip) do
      {:ok, tuple} -> member?(tuple, cidrs)
      :error -> false
    end
  end

  def member?(ip, cidrs) when is_tuple(ip) do
    {family, n} = to_int(unmap(ip))

    Enum.any?(cidrs, fn cidr ->
      {f, net, mask} = parse!(cidr)
      f == family and (n &&& mask) == net
    end)
  end

  @doc "The canonical string form of an IP tuple."
  def to_string(ip) when is_tuple(ip), do: ip |> unmap() |> :inet.ntoa() |> List.to_string()

  defp unmap({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: {hi >>> 8, hi &&& 255, lo >>> 8, lo &&& 255}
  defp unmap(ip), do: ip

  defp to_int({_, _, _, _} = ip), do: {4, fold(Tuple.to_list(ip), 8)}
  defp to_int({_, _, _, _, _, _, _, _} = ip), do: {6, fold(Tuple.to_list(ip), 16)}

  defp fold(parts, width), do: Enum.reduce(parts, 0, &((&2 <<< width) + &1))

  defp size(4), do: 32
  defp size(6), do: 128

  defp prefix(:host, size), do: {:ok, size}
  defp prefix({bits, ""}, size) when bits >= 0 and bits <= size, do: {:ok, bits}
  defp prefix(_, _), do: :error

  defp mask(bits, size), do: ((1 <<< bits) - 1) <<< (size - bits)
end
