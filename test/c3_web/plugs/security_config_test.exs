defmodule C3Web.Plugs.SecurityConfigTest do
  # Not async: these tests change global app env, so they run after the async modules.
  use C3Web.ConnCase, async: false

  import C3.Fixtures

  alias C3.{Repo, Security}
  alias C3.Security.BanCache
  alias C3Web.Plugs.RealIp

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

  defp real_ip(peer, headers) do
    conn =
      Enum.reduce(headers, with_ip(build_conn(), peer), fn {k, v}, c ->
        put_req_header(c, k, v)
      end)

    RealIp.call(conn, []).assigns.client_ip
  end

  describe "RealIp" do
    test "without a configured header, the peer address wins" do
      assert real_ip({10, 0, 0, 2}, [{"x-forwarded-for", "203.0.113.9"}]) == "10.0.0.2"
    end

    test "the header is honored only from a trusted proxy, read from the right" do
      put_config(:real_ip_header, "x-forwarded-for")

      # A client prepending a fake entry does not get it picked.
      assert real_ip({10, 0, 0, 2}, [{"x-forwarded-for", "1.1.1.1, 203.0.113.9, 10.0.0.5"}]) ==
               "203.0.113.9"

      # From an untrusted peer the header is ignored.
      assert real_ip({203, 0, 113, 50}, [{"x-forwarded-for", "1.1.1.1"}]) == "203.0.113.50"

      # Garbage or only trusted hops fall back sensibly.
      assert real_ip({10, 0, 0, 2}, [{"x-forwarded-for", "garbage"}]) == "10.0.0.2"
      assert real_ip({10, 0, 0, 2}, [{"x-forwarded-for", "192.168.1.4"}]) == "192.168.1.4"
    end

    test "a single-value header works the same" do
      put_config(:real_ip_header, "x-real-ip")
      assert real_ip({127, 0, 0, 1}, [{"x-real-ip", "2001:db8::7"}]) == "2001:db8::7"
    end
  end

  test "the ban hits the IP from the trusted header, not the proxy", %{conn: conn} do
    put_config(:real_ip_header, "x-forwarded-for")
    %{"session_code" => code} = conn |> post(~p"/v1/sessions", %{}) |> json_response(201)

    with_ip(build_conn(), {10, 0, 0, 2})
    |> put_req_header("x-forwarded-for", "203.0.113.77")
    |> post(~p"/v1/sessions/#{code}/join", %{"secret" => "x"})
    |> json_response(403)

    assert Security.banned_until("203.0.113.77")
    refute Security.banned_until("10.0.0.2")
  end

  test "an allowlisted IP is never banned, though its failure is recorded", %{conn: conn} do
    put_config(:ip_allowlist, ["198.18.0.0/15"])
    %{"session_code" => code} = conn |> post(~p"/v1/sessions", %{}) |> json_response(201)
    ip = unique_ip()

    for _ <- 1..2 do
      assert %{"error" => %{"code" => "invalid_secret"}} =
               with_ip(build_conn(), ip)
               |> post(~p"/v1/sessions/#{code}/join", %{"secret" => "x"})
               |> json_response(403)
    end

    refute Security.banned_until(ip_string(ip))
    refute Repo.get_by(C3.Security.IpBan, ip: ip_string(ip))
    assert Repo.aggregate(C3.Security.JoinFailure, :count) >= 2
  end

  describe "rate limit" do
    test "per IP: 429 with retry-after once over the limit", %{conn: conn} do
      put_config(:rate_limit_ip, 2)

      for _ <- 1..2,
          do: conn |> post(~p"/v1/sessions/C3-0000-0000/join", %{}) |> json_response(404)

      limited = post(conn, ~p"/v1/sessions/C3-0000-0000/join", %{})
      assert %{"error" => %{"code" => "rate_limited"}} = json_response(limited, 429)
      assert [retry] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry) in 1..60
    end

    test "per token, independent of the IP", %{conn: conn} do
      put_config(:rate_limit_token, 2)

      %{"session_code" => code, "agent" => %{"token" => token}} =
        conn |> post(~p"/v1/sessions", %{}) |> json_response(201)

      get_as = fn ->
        with_ip(build_conn(), unique_ip())
        |> put_req_header("authorization", "Bearer " <> token)
        |> get(~p"/v1/sessions/#{code}")
      end

      assert json_response(get_as.(), 200)
      assert json_response(get_as.(), 200)
      assert %{"error" => %{"code" => "rate_limited"}} = json_response(get_as.(), 429)
    end
  end

  test "BanCache.load/0 mirrors the bans in force from the table" do
    ip = ip_string(unique_ip())
    ip_ban_fixture(%{ip: ip})
    expired = ip_string(unique_ip())
    ip_ban_fixture(%{ip: expired, banned_until: DateTime.add(DateTime.utc_now(), -1)})
    lifted = ip_string(unique_ip())
    ip_ban_fixture(%{ip: lifted, lifted_at: DateTime.utc_now()})

    refute Security.banned_until(ip)
    BanCache.load()

    assert Security.banned_until(ip)
    refute Security.banned_until(expired)
    refute Security.banned_until(lifted)
  end
end
