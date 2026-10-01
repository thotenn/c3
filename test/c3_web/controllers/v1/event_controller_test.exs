defmodule C3Web.V1.EventControllerTest do
  use C3Web.ConnCase

  import Ecto.Query

  alias C3.Repo
  alias C3.Sessions.{Agent, Session}

  defp fresh_conn, do: with_ip(build_conn(), unique_ip())

  defp authed(token), do: put_req_header(fresh_conn(), "authorization", "Bearer " <> token)

  # A session with AG1 and AG2: %{code, t1, t2}. Its feed starts with two agent.joined.
  defp session! do
    created = fresh_conn() |> post(~p"/v1/sessions", %{}) |> json_response(201)
    %{"session_code" => code, "secret" => secret, "agent" => %{"token" => t1}} = created

    %{"agent" => %{"token" => t2}} =
      fresh_conn()
      |> post(~p"/v1/sessions/#{code}/join", %{"secret" => secret})
      |> json_response(201)

    %{code: code, t1: t1, t2: t2}
  end

  defp open_thread(s) do
    authed(s.t1)
    |> post(~p"/v1/sessions/#{s.code}/threads", %{"title" => "Deploy?", "body" => "Can you?"})
    |> json_response(201)
  end

  defp later(delay_ms, fun) do
    Task.async(fn ->
      Process.sleep(delay_ms)
      fun.()
    end)
  end

  defp poll(s, query), do: authed(s.t2) |> get(~p"/v1/sessions/#{s.code}/events?#{query}")

  defp elapsed_ms(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  defp put_config(key, value) do
    previous = Application.get_env(:c3, key)
    Application.put_env(:c3, key, value)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:c3, key),
        else: Application.put_env(:c3, key, previous)
    end)
  end

  defp session_row(s), do: Repo.get_by!(Session, code: s.code)

  defp age_activity(s, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)
    Repo.update_all(from(x in Session, where: x.code == ^s.code), set: [last_activity_at: at])

    Repo.update_all(from(a in Agent, where: a.session_id == ^session_row(s).id),
      set: [last_seen_at: at]
    )

    at
  end

  setup do: %{s: session!()}

  describe "GET /events (long-poll)" do
    test "returns the events after the cursor, with readable refs", %{s: s} do
      assert %{
               "events" => [
                 %{"seq" => 1, "type" => "agent.joined", "actor" => "AG1"},
                 %{"seq" => 2, "type" => "agent.joined", "actor" => "AG2", "thread" => nil}
               ],
               "last_seq" => 2
             } = poll(s, after: 0) |> json_response(200)

      assert %{"events" => [%{"seq" => 2}], "last_seq" => 2} =
               poll(s, after: 1) |> json_response(200)
    end

    test "with nothing new and no wait, answers empty at once with the same cursor", %{s: s} do
      assert %{"events" => [], "last_seq" => 2} = poll(s, after: 2) |> json_response(200)
    end

    test "is held until an event is committed", %{s: s} do
      task = later(150, fn -> open_thread(s) end)
      {ms, conn} = elapsed_ms(fn -> poll(s, after: 2, wait: 10) end)
      Task.await(task)

      assert %{
               "events" => [
                 %{
                   "seq" => 3,
                   "type" => "thread.opened",
                   "actor" => "AG1",
                   "thread" => "T1",
                   "payload" => %{"opened_by" => "AG1", "to" => ["any"]}
                 }
               ],
               "last_seq" => 3
             } = json_response(conn, 200)

      assert ms >= 150 and ms < 5_000
    end

    test "respects wait, and caps it at long_poll_max_wait", %{s: s} do
      {ms, conn} = elapsed_ms(fn -> poll(s, after: 2, wait: 1) end)
      assert %{"events" => []} = json_response(conn, 200)
      assert ms >= 1_000 and ms < 3_000

      put_config(:long_poll_max_wait, 1)
      {ms, conn} = elapsed_ms(fn -> poll(s, after: 2, wait: 600) end)
      assert %{"events" => []} = json_response(conn, 200)
      assert ms >= 1_000 and ms < 3_000
    end

    test "no event is lost between two polls", %{s: s} do
      %{"last_seq" => cursor} = poll(s, after: 0) |> json_response(200)
      open_thread(s)
      open_thread(s)

      assert %{"events" => [%{"seq" => 3}, %{"seq" => 4}], "last_seq" => 4} =
               poll(s, after: cursor, wait: 5) |> json_response(200)
    end

    test "limit pages the backlog", %{s: s} do
      assert %{"events" => [%{"seq" => 1}], "last_seq" => 1} =
               poll(s, after: 0, limit: 1) |> json_response(200)
    end

    test "a close while waiting answers with session.closed; the next poll is 410", %{s: s} do
      task = later(100, fn -> authed(s.t1) |> post(~p"/v1/sessions/#{s.code}/close", %{}) end)
      conn = poll(s, after: 2, wait: 10)
      Task.await(task)

      assert %{"events" => [%{"type" => "session.closed", "actor" => "AG1"}]} =
               json_response(conn, 200)

      assert %{"error" => %{"code" => "session_closed"}} =
               poll(s, after: 3) |> json_response(410)
    end

    test "bad parameters are 422; no token is 401", %{s: s} do
      assert %{"error" => %{"code" => "invalid_request"}} =
               poll(s, after: "x") |> json_response(422)

      assert poll(s, wait: -1) |> json_response(422)
      assert fresh_conn() |> get(~p"/v1/sessions/#{s.code}/events") |> json_response(401)
    end
  end

  describe "activity and presence" do
    test "the feed and /heartbeat are presence, not session activity", %{s: s} do
      old = age_activity(s, 2 * 3600)

      poll(s, after: 0) |> json_response(200)

      assert %{"ok" => true, "you" => "AG2"} =
               authed(s.t2) |> post(~p"/v1/heartbeat", %{}) |> json_response(200)

      assert session_row(s).last_activity_at == old
      seen = Repo.get_by!(Agent, session_id: session_row(s).id, name: "AG2").last_seen_at
      assert DateTime.compare(seen, old) == :gt
    end

    test "any other request renews the session's last_activity_at, throttled", %{s: s} do
      old = age_activity(s, 2 * 3600)

      authed(s.t2) |> get(~p"/v1/inbox") |> json_response(200)
      renewed = session_row(s).last_activity_at
      assert DateTime.compare(renewed, old) == :gt

      authed(s.t1) |> get(~p"/v1/sessions/#{s.code}") |> json_response(200)
      assert session_row(s).last_activity_at == renewed
    end
  end

  describe "GET /events/stream (SSE)" do
    defp stream(s, conn \\ nil) do
      (conn || authed(s.t2))
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/v1/sessions/#{s.code}/events/stream")
    end

    defp close_later(s, delay_ms) do
      later(delay_ms, fn -> authed(s.t1) |> post(~p"/v1/sessions/#{s.code}/close", %{}) end)
    end

    defp frames(body) do
      body
      |> String.split("\n\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "id: "))
      |> Enum.map(fn frame ->
        ["id: " <> id, "event: " <> type, "data: " <> data] = String.split(frame, "\n")
        {String.to_integer(id), type, Jason.decode!(data)}
      end)
    end

    test "streams the backlog and the new events, and ends with session.closed", %{s: s} do
      task = later(100, fn -> open_thread(s) end)
      closing = close_later(s, 250)
      conn = stream(s)
      Task.await(task)
      Task.await(closing)

      assert conn.status == 200
      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert conn.resp_body =~ ~r/\Aretry: 3000\n\n/

      assert [
               {1, "agent.joined", %{"actor" => "AG1"}},
               {2, "agent.joined", _},
               {3, "thread.opened", %{"thread" => "T1"}},
               {4, "session.closed", %{"payload" => %{"reason" => "manual"}}}
             ] = frames(conn.resp_body)
    end

    test "resumes after Last-Event-ID", %{s: s} do
      closing = close_later(s, 100)
      conn = s |> stream(authed(s.t2) |> put_req_header("last-event-id", "2"))
      Task.await(closing)

      assert [{3, "session.closed", _}] = frames(conn.resp_body)
    end

    test "?after= works when there is no Last-Event-ID", %{s: s} do
      closing = close_later(s, 100)

      conn =
        authed(s.t2)
        |> put_req_header("accept", "text/event-stream")
        |> get(~p"/v1/sessions/#{s.code}/events/stream?after=1")

      Task.await(closing)
      assert [{2, _, _}, {3, "session.closed", _}] = frames(conn.resp_body)
    end

    test "ends when the agent itself leaves", %{s: s} do
      task = later(100, fn -> authed(s.t2) |> post(~p"/v1/sessions/#{s.code}/leave", %{}) end)
      conn = s |> stream(authed(s.t2) |> put_req_header("last-event-id", "2"))
      Task.await(task)

      assert [{3, "agent.left", %{"actor" => "AG2"}}] = frames(conn.resp_body)
    end

    test "sends a keepalive comment while idle", %{s: s} do
      put_config(:sse_keepalive, 1)
      closing = close_later(s, 1_300)
      conn = s |> stream(authed(s.t2) |> put_req_header("last-event-id", "2"))
      Task.await(closing, 5_000)

      assert conn.resp_body =~ ": keepalive\n\n"
      assert [{3, "session.closed", _}] = frames(conn.resp_body)
    end

    test "an invalid Last-Event-ID is 422; no token is 401", %{s: s} do
      assert %{"error" => %{"code" => "invalid_request"}} =
               s
               |> stream(authed(s.t2) |> put_req_header("last-event-id", "abc"))
               |> json_response(422)

      assert s |> stream(fresh_conn()) |> json_response(401)
    end
  end
end
