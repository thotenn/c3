defmodule C3Web.V1.SessionControllerTest do
  use C3Web.ConnCase

  import C3.Fixtures

  alias C3.{Events, Repo, Sessions}
  alias C3.Security.{IpBan, JoinFailure}
  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.Message

  defp create(conn, body \\ %{}) do
    conn |> post(~p"/v1/sessions", body) |> json_response(201)
  end

  defp join(conn, code, body), do: post(conn, ~p"/v1/sessions/#{code}/join", body)

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp fresh_conn, do: with_ip(build_conn(), unique_ip())

  defp event_types(code) do
    code |> Sessions.get_session_by_code() |> Events.list_after(0) |> Enum.map(& &1.type)
  end

  describe "POST /v1/sessions" do
    test "creates a session with AG1 and returns the clear credentials once", %{conn: conn} do
      body = create(conn, %{"label" => "Sprint review", "agent_label" => "front-laptop"})

      assert %{
               "session_code" => code,
               "secret" => secret,
               "agent" => %{"name" => "AG1", "label" => "front-laptop", "token" => token},
               "expires_at" => _
             } = body

      assert code =~ ~r/^C3-\w{4}-\w{4}$/
      assert secret =~ ~r/^\d{6}$/

      session = Sessions.get_session_by_code(code)
      assert session.label == "Sprint review"
      assert session.next_agent_number == 2
      refute session.secret_hash =~ secret
      assert C3.Credentials.verify_secret(secret, session.secret_hash)

      agent = Sessions.get_agent_by_token(token)
      assert agent.name == "AG1"
      refute agent.token_hash == token
      assert event_types(code) == [:agent_joined]
    end

    test "rejects an invalid agent label", %{conn: conn} do
      body = conn |> post(~p"/v1/sessions", %{"agent_label" => "Bad Label"}) |> json_response(422)

      assert %{"error" => %{"code" => "invalid_request", "details" => %{"agent_label" => _}}} =
               body
    end

    test "rejects a session label over 200 characters", %{conn: conn} do
      body =
        conn
        |> post(~p"/v1/sessions", %{"label" => String.duplicate("x", 201)})
        |> json_response(422)

      assert %{"error" => %{"code" => "invalid_request", "details" => %{"label" => _}}} = body
    end
  end

  describe "POST /v1/sessions/:code/join" do
    setup %{conn: conn}, do: %{created: create(conn)}

    test "joins as the next AGn, with a label; codes are forgiving", %{created: created} do
      %{"session_code" => code, "secret" => secret} = created
      sloppy = code |> String.downcase() |> String.replace("-", " ")

      body = fresh_conn() |> join(sloppy, %{"secret" => secret, "agent_label" => "backend-win"})

      assert %{"session_code" => ^code, "agent" => %{"name" => "AG2", "token" => "c3_" <> _}} =
               json_response(body, 201)

      assert event_types(code) == [:agent_joined, :agent_joined]
    end

    test "names are never reused, even after an agent leaves", %{created: created} do
      %{"session_code" => code, "secret" => secret} = created

      %{"agent" => %{"name" => "AG2", "token" => token2}} =
        fresh_conn() |> join(code, %{"secret" => secret}) |> json_response(201)

      fresh_conn() |> authed(token2) |> post(~p"/v1/sessions/#{code}/leave") |> json_response(200)

      assert %{"agent" => %{"name" => "AG3"}} =
               fresh_conn() |> join(code, %{"secret" => secret}) |> json_response(201)
    end

    test "wrong secrets past the tolerance ban the IP, and every one alerts the session",
         %{created: created} do
      %{"session_code" => code, "secret" => secret} = created
      ip = unique_ip()

      bodies =
        for _ <- 1..3 do
          with_ip(build_conn(), ip)
          |> put_req_header("user-agent", "curl/8")
          |> join(code, %{"secret" => wrong(secret), "agent_label" => "intruder"})
          |> json_response(403)
        end

      assert Enum.all?(bodies, &(&1["error"]["code"] == "invalid_secret"))

      ban = Repo.get_by!(IpBan, ip: ip_string(ip))
      assert ban.reason == :invalid_secret
      assert ban.session_code == code
      assert ban.ip_full == ip_string(ip)
      assert DateTime.diff(ban.banned_until, ban.inserted_at) in 59..60

      # Even the right secret is refused now, and so is creating a session.
      assert %{"error" => %{"code" => "ip_banned", "details" => %{"banned_until" => _}}} =
               with_ip(build_conn(), ip)
               |> join(code, %{"secret" => secret})
               |> json_response(403)

      assert %{"error" => %{"code" => "ip_banned"}} =
               with_ip(build_conn(), ip) |> post(~p"/v1/sessions", %{}) |> json_response(403)

      session = Sessions.get_session_by_code(code)
      [_joined, _, _, failed] = Events.list_after(session, 0)
      assert failed.type == :security_join_failed
      assert failed.payload["banned_until"]

      assert %{"ip" => ip_str, "user_agent" => "curl/8", "attempted_label" => "intruder"} =
               failed.payload

      assert ip_str == ip_string(ip)
    end

    test "a live token keeps working from a banned IP", %{created: created} do
      %{"session_code" => code, "secret" => secret, "agent" => %{"token" => token}} = created
      ip = unique_ip()

      for _ <- 1..3,
          do:
            with_ip(build_conn(), ip)
            |> join(code, %{"secret" => wrong(secret)})
            |> json_response(403)

      assert C3.Security.banned_until(ip_string(ip))

      assert %{"you" => "AG1"} =
               with_ip(build_conn(), ip)
               |> authed(token)
               |> get(~p"/v1/sessions/#{code}")
               |> json_response(200)
    end

    test "wrong secrets from K distinct IPs lock joins until an agent inside unlocks",
         %{created: created} do
      %{"session_code" => code, "secret" => secret, "agent" => %{"token" => token}} = created

      for _ <- 1..3 do
        fresh_conn() |> join(code, %{"secret" => wrong(secret)}) |> json_response(403)
      end

      assert Sessions.get_session_by_code(code).joins_locked_at
      assert :session_joins_locked in event_types(code)

      # Locked: the right secret is refused, without checking it and without a ban.
      ip = unique_ip()

      assert %{"error" => %{"code" => "joins_locked"}} =
               with_ip(build_conn(), ip)
               |> join(code, %{"secret" => secret})
               |> json_response(423)

      refute C3.Security.banned_until(ip_string(ip))
      assert Repo.get_by!(JoinFailure, ip: ip_string(ip)).reason == :joins_locked

      assert %{"session" => %{"joins_locked" => true}} =
               fresh_conn()
               |> authed(token)
               |> get(~p"/v1/sessions/#{code}")
               |> json_response(200)

      assert %{"unlocked" => true} =
               fresh_conn()
               |> authed(token)
               |> post(~p"/v1/sessions/#{code}/unlock")
               |> json_response(200)

      assert %{"unlocked" => false} =
               fresh_conn()
               |> authed(token)
               |> post(~p"/v1/sessions/#{code}/unlock")
               |> json_response(200)

      assert :session_joins_unlocked in event_types(code)

      # The failures before the unlock do not count again: one more does not relock.
      fresh_conn() |> join(code, %{"secret" => wrong(secret)}) |> json_response(403)
      refute Sessions.get_session_by_code(code).joins_locked_at

      assert %{"agent" => %{"name" => "AG2"}} =
               with_ip(build_conn(), ip)
               |> join(code, %{"secret" => secret})
               |> json_response(201)
    end

    test "joining a closed session is 410, recorded, and not banned", %{created: created} do
      %{"session_code" => code, "secret" => secret, "agent" => %{"token" => token}} = created
      fresh_conn() |> authed(token) |> post(~p"/v1/sessions/#{code}/close") |> json_response(200)

      ip = unique_ip()

      assert %{"error" => %{"code" => "session_closed"}} =
               with_ip(build_conn(), ip)
               |> join(code, %{"secret" => secret})
               |> json_response(410)

      assert Repo.get_by!(JoinFailure, ip: ip_string(ip)).reason == :session_closed
      refute C3.Security.banned_until(ip_string(ip))
    end
  end

  describe "start" do
    test "GET start resumes: the session, inbox, memory and reservations; seen alerts go" do
      %{"session_code" => code, "secret" => secret, "agent" => %{"token" => t1}} =
        create(fresh_conn())

      join(fresh_conn(), code, %{"secret" => "000000x"})

      assert %{
               "session" => %{"you" => "AG1", "session" => %{"code" => ^code}, "agents" => [_]},
               "inbox" => %{"alerts" => [%{"type" => "security.join_failed"}]},
               "knowledge" => [],
               "reservations" => []
             } =
               fresh_conn()
               |> authed(t1)
               |> get(~p"/v1/sessions/#{code}/start")
               |> json_response(200)

      assert %{"inbox" => %{"empty" => true}} =
               fresh_conn()
               |> authed(t1)
               |> get(~p"/v1/sessions/#{code}/start")
               |> json_response(200)

      body = fresh_conn() |> join(code, %{"secret" => secret}) |> json_response(201)
      refute Map.has_key?(body, "start"), "a plain join answers as before"

      other = create(fresh_conn())

      assert fresh_conn()
             |> authed(t1)
             |> get(~p"/v1/sessions/#{other["session_code"]}/start")
             |> json_response(403)
    end
  end

  describe "unknown codes (enumeration)" do
    test "count as failures and ban at the 5th of the day, not before", %{conn: conn} do
      ip = unique_ip()
      conn = with_ip(conn, ip)

      for i <- 1..5 do
        code = "C3-ZZZZ-ZZZ#{i}"

        assert %{"error" => %{"code" => "not_found"}} =
                 conn |> join(code, %{"secret" => "000000"}) |> json_response(404)

        if i < 5, do: refute(C3.Security.banned_until(ip_string(ip)))
      end

      assert Repo.get_by!(IpBan, ip: ip_string(ip)).reason == :unknown_code

      assert %{"error" => %{"code" => "ip_banned"}} =
               with_ip(build_conn(), ip) |> join("C3-ZZZZ-ZZZ6", %{}) |> json_response(403)
    end

    test "a malformed code counts too and keeps what was sent", %{conn: conn} do
      ip = unique_ip()
      with_ip(conn, ip) |> join("hello", %{"secret" => "1"}) |> json_response(404)

      assert %JoinFailure{reason: :unknown_code, attempted_code: "hello", session_id: nil} =
               Repo.get_by!(JoinFailure, ip: ip_string(ip))
    end
  end

  describe "authenticated routes" do
    setup %{conn: conn} do
      created = create(conn, %{"agent_label" => "front"})

      %{"agent" => %{"token" => token2}} =
        fresh_conn()
        |> join(created["session_code"], %{"secret" => created["secret"], "agent_label" => "back"})
        |> json_response(201)

      %{
        created: created,
        code: created["session_code"],
        token1: created["agent"]["token"],
        token2: token2
      }
    end

    test "GET shows metadata, agents and threads, without internal ids", ctx do
      session = Sessions.get_session_by_code(ctx.code)
      ag1 = Sessions.get_agent_by_token(ctx.token1)
      thread_fixture(ag1, %{number: 1, title: "Need the endpoint"})

      body =
        fresh_conn()
        |> authed(ctx.token2)
        |> get(~p"/v1/sessions/#{ctx.code}")
        |> json_response(200)

      assert body["you"] == "AG2"
      assert body["session"]["code"] == session.code
      assert body["session"]["status"] == "open"

      assert [
               %{"name" => "AG1", "label" => "front", "status" => "active"},
               %{"name" => "AG2", "label" => "back"}
             ] = body["agents"]

      assert [%{"id" => "T1", "title" => "Need the endpoint", "opened_by" => "AG1"}] =
               body["threads"]

      refute inspect(body) =~ ~r/"id" => \d/
      refute Map.has_key?(hd(body["agents"]), "token")
    end

    test "401 without or with an unknown token; 403 with a token of another session", ctx do
      assert %{"error" => %{"code" => "unauthorized"}} =
               fresh_conn() |> get(~p"/v1/sessions/#{ctx.code}") |> json_response(401)

      assert %{"error" => %{"code" => "unauthorized"}} =
               fresh_conn()
               |> authed("c3_nope")
               |> get(~p"/v1/sessions/#{ctx.code}")
               |> json_response(401)

      %{"agent" => %{"token" => other}} = create(fresh_conn())

      assert %{"error" => %{"code" => "forbidden"}} =
               fresh_conn()
               |> authed(other)
               |> get(~p"/v1/sessions/#{ctx.code}")
               |> json_response(403)
    end

    test "leave revokes the token and puts its claimed requests back to open", ctx do
      ag1 = Sessions.get_agent_by_token(ctx.token1)
      ag2 = Sessions.get_agent_by_token(ctx.token2)
      thread = thread_fixture(ag1, %{number: 4})

      claimed =
        request_fixture(thread, ag1, ag2, %{number: 2})
        |> Ecto.Changeset.change(
          request_state: :claimed,
          claimed_by_agent_id: ag2.id,
          claimed_at: DateTime.utc_now()
        )
        |> Repo.update!()

      body =
        fresh_conn()
        |> authed(ctx.token2)
        |> post(~p"/v1/sessions/#{ctx.code}/leave")
        |> json_response(200)

      assert body == %{"left" => true, "released" => ["T4.2"]}

      assert %Message{request_state: :open, claimed_by_agent_id: nil, claimed_at: nil} =
               Repo.reload!(claimed)

      assert %Agent{status: :left, left_at: %DateTime{}} = Repo.reload!(ag2)

      assert %{"error" => %{"code" => "unauthorized"}} =
               fresh_conn()
               |> authed(ctx.token2)
               |> get(~p"/v1/sessions/#{ctx.code}")
               |> json_response(401)

      [left] =
        ctx.code
        |> Sessions.get_session_by_code()
        |> Events.list_after(0)
        |> Enum.filter(&(&1.type == :agent_left))

      assert left.payload == %{"name" => "AG2", "released" => ["T4.2"]}
    end

    test "close is irreversible: every route of the session answers 410", ctx do
      body =
        fresh_conn()
        |> authed(ctx.token2)
        |> post(~p"/v1/sessions/#{ctx.code}/close")
        |> json_response(200)

      assert %{"status" => "closed", "closed_by" => "AG2"} = body

      session = Sessions.get_session_by_code(ctx.code)
      assert %Session{status: :closed, close_reason: :manual, closed_by: "AG2"} = session
      assert Enum.all?(Sessions.list_agents(session), &(&1.status == :revoked))
      assert List.last(event_types(ctx.code)) == :session_closed

      for token <- [ctx.token1, ctx.token2],
          {method, path} <- [
            {:get, ~p"/v1/sessions/#{ctx.code}"},
            {:post, ~p"/v1/sessions/#{ctx.code}/leave"},
            {:post, ~p"/v1/sessions/#{ctx.code}/close"},
            {:post, ~p"/v1/sessions/#{ctx.code}/unlock"}
          ] do
        conn = fresh_conn() |> authed(token) |> dispatch(@endpoint, method, path, nil)
        assert %{"error" => %{"code" => "session_closed"}} = json_response(conn, 410)
      end

      assert %{"error" => %{"code" => "session_closed"}} =
               fresh_conn()
               |> join(ctx.code, %{"secret" => ctx.created["secret"]})
               |> json_response(410)
    end
  end

  defp wrong(secret) do
    secret
    |> String.to_integer()
    |> Kernel.+(1)
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
