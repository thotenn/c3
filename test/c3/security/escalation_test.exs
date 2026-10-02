defmodule C3.Security.EscalationTest do
  @moduledoc "C3-3 F3: tolerance, ban steps, repeat offenders and the IPv6 subject."
  use C3.DataCase

  alias C3.{Config, LocalTime, Security, Sessions}
  alias C3.Security.IpBan

  # BanCache is a global ETS table, outside the sandbox: every test gets its own network.
  setup do
    n =
      String.downcase(Integer.to_string(rem(System.unique_integer([:positive]), 0xFFFF) + 1, 16))

    net = "2001:db8:#{n}:2"
    %{v6_a: "#{net}::a", v6_b: "#{net}:ffff::b", net: "#{net}::/64", other: "2001:db8:#{n}:3::1"}
  end

  defp put_config(key, value) do
    previous = Application.fetch_env(:c3, key)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:c3, key, v)
        :error -> Application.delete_env(:c3, key)
      end
    end)

    Application.put_env(:c3, key, value)
  end

  defp unique_ip do
    n = System.unique_integer([:positive])
    "198.#{18 + rem(div(n, 65_536), 2)}.#{rem(div(n, 256), 256)}.#{rem(n, 256)}"
  end

  defp session do
    {:ok, %{session: s, secret: secret}} = Sessions.create_session(%{}, %{ip: "192.0.2.1"})
    {s, secret}
  end

  defp wrong({s, _}, ip), do: Sessions.join_session(s.code, %{"secret" => "x"}, %{ip: ip})
  defp right({s, secret}, ip), do: Sessions.join_session(s.code, %{"secret" => secret}, %{ip: ip})

  defp ban_seconds(ip) do
    ban =
      IpBan
      |> where(ip: ^Security.CIDR.subject(ip))
      |> order_by(desc: :id)
      |> limit(1)
      |> Repo.one!()

    DateTime.diff(ban.banned_until, ban.inserted_at)
  end

  defp capped(seconds) do
    now = DateTime.utc_now()
    min(seconds, DateTime.diff(LocalTime.next_midnight(now), now))
  end

  test "the first C3_SECRET_TOLERANCE wrong secrets go without a ban" do
    s = session()
    ip = unique_ip()

    for _ <- 1..Config.get(:secret_tolerance) do
      assert {:error, :invalid_secret} = wrong(s, ip)
      refute Security.banned_until(ip)
    end

    assert {:error, :invalid_secret} = wrong(s, ip)
    assert Security.banned_until(ip)
    assert {:error, :ip_banned, _} = right(s, ip)
  end

  test "a tolerance of 0 bans at the first wrong secret" do
    put_config(:secret_tolerance, 0)
    s = session()
    ip = unique_ip()
    assert {:error, :invalid_secret} = wrong(s, ip)
    assert Security.banned_until(ip)
  end

  test "the ban grows 1 min → 10 min → 1 h within one session" do
    s = session()
    ip = unique_ip()
    for _ <- 1..2, do: wrong(s, ip)

    for expected <- [60, 600, 3600, 3600] do
      assert {:error, :invalid_secret} = wrong(s, ip)
      assert_in_delta ban_seconds(ip), capped(expected), 1
      Security.unban(ip)
    end
  end

  test "a ban in a second session the same day lasts until midnight" do
    ip = unique_ip()
    a = session()
    for _ <- 1..3, do: wrong(a, ip)
    assert_in_delta ban_seconds(ip), capped(60), 1
    Security.unban(ip)

    b = session()
    for _ <- 1..3, do: wrong(b, ip)
    ban = IpBan |> where(ip: ^ip) |> order_by(desc: :id) |> limit(1) |> Repo.one!()
    assert ban.banned_until == LocalTime.next_midnight(ban.inserted_at)
  end

  test "tolerated typos in two sessions are not a repeat offense" do
    ip = unique_ip()
    a = session()
    b = session()
    wrong(a, ip)
    wrong(b, ip)
    refute Security.banned_until(ip)
    assert {:ok, _} = right(a, ip)
  end

  test "two addresses of one /64 are one subject", v6 do
    s = session()
    wrong(s, v6.v6_a)
    wrong(s, v6.v6_b)
    refute Security.banned_until(v6.v6_a)
    assert {:error, :invalid_secret} = wrong(s, v6.v6_a)

    assert Security.banned_until(v6.v6_b)
    assert {:error, :ip_banned, _} = right(s, v6.v6_b)
    refute Security.banned_until(v6.other)

    ban = Repo.get_by!(IpBan, ip: v6.net)
    assert ban.ip_full == v6.v6_a

    [failure | _] = Repo.all(C3.Security.JoinFailure)
    assert failure.ip == v6.net
    assert failure.ip_full in [v6.v6_a, v6.v6_b]
  end

  test "C3_IPV6_PREFIX narrows the subject", v6 do
    put_config(:ipv6_prefix, 128)
    put_config(:secret_tolerance, 0)
    s = session()
    wrong(s, v6.v6_a)
    assert Security.banned_until(v6.v6_a)
    refute Security.banned_until(v6.v6_b)
  end

  test "unban takes the network or any address in it", v6 do
    put_config(:secret_tolerance, 0)
    s = session()
    wrong(s, v6.v6_a)
    assert Security.unban(v6.v6_b) == 1
    refute Security.banned_until(v6.v6_a)

    wrong(s, v6.v6_a)
    assert Security.unban(String.upcase(v6.net)) == 1
    refute Security.banned_until(v6.v6_a)
  end

  test "an allowlisted IPv6 network is never banned", v6 do
    put_config(:ip_allowlist, ["2001:db8::/32"])
    put_config(:secret_tolerance, 0)
    s = session()
    wrong(s, v6.v6_a)
    refute Security.banned_until(v6.v6_a)
    refute Repo.get_by(IpBan, ip: v6.net)
    assert Security.allowlisted?(v6.net)
  end

  test "the join lock counts subjects: one /64 does not lock a session", v6 do
    s = session()
    for i <- 1..9, do: wrong(s, String.replace(v6.v6_a, "::a", "::#{i}"))
    refute Repo.reload!(elem(s, 0)).joins_locked_at
  end

  test "with tolerance, the lock comes after 2 × (tolerance + 1) + 1 wrong secrets" do
    s = session()
    [ip1, ip2, ip3] = for _ <- 1..3, do: unique_ip()

    # Two subjects use their tolerance and get banned; the third subject's first failure locks.
    for ip <- [ip1, ip2], _ <- 1..3, do: assert({:error, :invalid_secret} = wrong(s, ip))
    refute Repo.reload!(elem(s, 0)).joins_locked_at
    assert {:error, :invalid_secret} = wrong(s, ip3)
    assert Repo.reload!(elem(s, 0)).joins_locked_at
    assert {:error, :joins_locked} = wrong(s, ip3)
  end

  test "unknown codes still ban until midnight at the limit" do
    ip = unique_ip()

    for _ <- 1..Config.get(:unknown_code_limit) do
      Sessions.join_session("C3-ZZZZ-ZZZZ", %{"secret" => "x"}, %{ip: ip})
    end

    ban = Repo.get_by!(IpBan, ip: ip, reason: :unknown_code)
    assert ban.banned_until == LocalTime.next_midnight(ban.inserted_at)
  end

  test "Config.validate!/0 checks the prefix and the tolerance" do
    put_config(:ipv6_prefix, 16)
    assert_raise ArgumentError, ~r/C3_IPV6_PREFIX/, &Config.validate!/0
    put_config(:ipv6_prefix, 64)
    put_config(:secret_tolerance, -1)
    assert_raise ArgumentError, ~r/C3_SECRET_TOLERANCE/, &Config.validate!/0
  end
end
