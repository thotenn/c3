defmodule C3.Repo.Migrations.AddIpFull do
  use Ecto.Migration

  import Bitwise

  # `ip` becomes the ban subject (an IPv4 address, or the IPv6 network of C3_IPV6_PREFIX);
  # `ip_full` keeps the exact address for the admin. Self-contained: no app module is used,
  # so the migration keeps working whatever C3.Security.CIDR turns into.

  @tables ~w(join_failures ip_bans)

  def up do
    for table <- @tables do
      alter table(table), do: add(:ip_full, :text)
    end

    flush()
    prefix = Application.get_env(:c3, :ipv6_prefix, 64)

    for table <- @tables do
      repo().query!("UPDATE #{table} SET ip_full = ip")

      %{rows: rows} = repo().query!("SELECT id, ip FROM #{table} WHERE ip LIKE '%:%'")

      for [id, ip] <- rows, subject = subject(ip, prefix), subject != ip do
        repo().query!("UPDATE #{table} SET ip = ? WHERE id = ?", [subject, id])
      end
    end
  end

  def down do
    for table <- @tables do
      execute "UPDATE #{table} SET ip = ip_full WHERE ip_full IS NOT NULL"
      alter table(table), do: remove(:ip_full)
    end
  end

  defp subject(ip, prefix) do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, hi, lo}} ->
        List.to_string(:inet.ntoa({hi >>> 8, hi &&& 255, lo >>> 8, lo &&& 255}))

      {:ok, {_, _, _, _, _, _, _, _} = v6} when prefix < 128 ->
        n = Enum.reduce(Tuple.to_list(v6), 0, &((&2 <<< 16) + &1))
        net = n &&& ((1 <<< prefix) - 1) <<< (128 - prefix)
        tuple = List.to_tuple(for i <- 7..0//-1, do: net >>> (16 * i) &&& 0xFFFF)
        "#{:inet.ntoa(tuple)}/#{prefix}"

      _ ->
        ip
    end
  end
end
