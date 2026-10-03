defmodule C3Web.V1.WatchTest do
  use C3Web.ConnCase

  import Ecto.Query, only: [where: 2]

  defp fresh_conn, do: with_ip(build_conn(), unique_ip())

  defp authed(token), do: put_req_header(fresh_conn(), "authorization", "Bearer " <> token)

  # AG1, AG2 (label `backend`) and AG3: %{code, secret, t1, t2, t3}. Seqs 1–3 are the joins.
  defp session! do
    created = fresh_conn() |> post(~p"/v1/sessions", %{}) |> json_response(201)
    %{"session_code" => code, "secret" => secret, "agent" => %{"token" => t1}} = created

    join = fn attrs ->
      fresh_conn()
      |> post(~p"/v1/sessions/#{code}/join", Map.put(attrs, "secret", secret))
      |> json_response(201)
      |> get_in(["agent", "token"])
    end

    %{
      code: code,
      secret: secret,
      t1: t1,
      t2: join.(%{"agent_label" => "backend"}),
      t3: join.(%{})
    }
  end

  defp open_thread(s, token, to, title \\ "Deploy?") do
    authed(token)
    |> post(~p"/v1/sessions/#{s.code}/threads", %{
      "title" => title,
      "body" => "Can you?",
      "to" => to
    })
    |> json_response(201)
  end

  defp watch_conn(s, token, query),
    do: authed(token) |> get(~p"/v1/sessions/#{s.code}/watch?#{query}")

  # `{cursor, lines}` of a watch with `wait=0` unless given.
  defp watch(s, token, query) do
    conn = watch_conn(s, token, Keyword.put_new(query, :wait, 0))
    ["cursor " <> cursor | lines] = conn |> response(200) |> String.split("\n", trim: true)
    {String.to_integer(cursor), lines}
  end

  defp lines(s, token, after_seq \\ 3), do: s |> watch(token, after: after_seq) |> elem(1)

  setup do: %{s: session!()}

  describe "GET /watch" do
    test "answers text/plain, with the cursor first", %{s: s} do
      conn = watch_conn(s, s.t2, after: 0)
      assert response_content_type(conn, :text) =~ "text/plain"
      assert response(conn, 200) == "cursor 3\n"
    end

    test "is not refused for Accept: text/plain", %{s: s} do
      conn =
        authed(s.t1)
        |> put_req_header("accept", "text/plain")
        |> get(~p"/v1/sessions/#{s.code}/watch?after=3")

      assert response(conn, 200) == "cursor 3\n"
    end

    test "a request by name wakes its target, not the others nor its author", %{s: s} do
      open_thread(s, s.t1, ["AG2"])

      assert [~s(request 4 T1.1 from AG1 "Deploy?")] = lines(s, s.t2)
      assert {cursor, []} = watch(s, s.t3, after: 3)
      assert cursor >= 4
      assert [] = lines(s, s.t1)
    end

    test "a request to a label wakes the agent with that label", %{s: s} do
      open_thread(s, s.t1, ["label:backend"])

      assert [~s(request 4 T1.1 from AG1 "Deploy?")] = lines(s, s.t2)
      assert [] = lines(s, s.t3)
    end

    test "a request to any wakes everyone but its author", %{s: s} do
      open_thread(s, s.t1, "any")

      assert ["request 4 T1.1 from AG1" <> _] = lines(s, s.t2)
      assert ["request 4 T1.1 from AG1" <> _] = lines(s, s.t3)
      assert [] = lines(s, s.t1)
    end

    test "a thread to several targets is one line, with the request of each", %{s: s} do
      open_thread(s, s.t1, ["AG3", "AG2"])

      assert ["request 4 T1.2 from AG1" <> _] = lines(s, s.t2)
      assert ["request 4 T1.1 from AG1" <> _] = lines(s, s.t3)
    end

    test "a request posted in an existing thread", %{s: s} do
      open_thread(s, s.t1, ["AG2"])
      {cursor, _} = watch(s, s.t3, after: 3)

      authed(s.t2)
      |> post(~p"/v1/threads/T1/messages", %{
        "kind" => "request",
        "to" => "AG3",
        "body" => "Logs?"
      })
      |> json_response(201)

      assert [line] = lines(s, s.t3, cursor)
      assert line =~ ~r/^request \d+ T1\.2 from AG2 "Deploy\?"$/
    end

    test "an answer wakes the agent that asked", %{s: s} do
      open_thread(s, s.t1, ["AG2"])
      {cursor, _} = watch(s, s.t1, after: 3)

      authed(s.t2)
      |> post(~p"/v1/threads/T1/messages", %{"kind" => "response", "body" => "Done"})
      |> json_response(201)

      assert [line] = lines(s, s.t1, cursor)
      assert line =~ ~r/^answer \d+ T1\.2 from AG2 resolves T1\.1 "Deploy\?"$/
      assert [] = lines(s, s.t3, cursor)
    end

    test "a cancellation wakes the agent that held the request", %{s: s} do
      open_thread(s, s.t1, ["AG2"])
      authed(s.t2) |> post(~p"/v1/threads/T1/claim", %{}) |> json_response(200)
      {cursor, _} = watch(s, s.t2, after: 3)

      authed(s.t1)
      |> post(~p"/v1/threads/T1/cancel", %{"request_id" => "T1.1", "reason" => "Not needed"})
      |> json_response(200)

      assert [line] = lines(s, s.t2, cursor)
      assert line =~ ~r/^cancelled \d+ T1\.1 by AG1 "Deploy\?"$/
      assert [] = lines(s, s.t3, cursor)
      assert [] = lines(s, s.t1, cursor)
    end

    test "knowledge entries wake nobody, but move the cursor", %{s: s} do
      record = fn token, attrs ->
        authed(token)
        |> post(
          ~p"/v1/sessions/#{s.code}/knowledge",
          Map.merge(%{"topic" => "auth", "kind" => "decision", "summary" => "JWT"}, attrs)
        )
        |> json_response(201)
      end

      record.(s.t1, %{})
      record.(s.t2, %{"supersedes" => "K1"})
      authed(s.t2) |> post(~p"/v1/knowledge/K2/retract", %{}) |> json_response(200)

      for token <- [s.t1, s.t2, s.t3] do
        assert {cursor, []} = watch(s, token, after: 3)
        assert cursor == 7
      end
    end

    test "importance and ack go on the request line; a note asking for an ack wakes", %{s: s} do
      authed(s.t1)
      |> post(~p"/v1/sessions/#{s.code}/threads", %{
        "title" => "Freeze",
        "body" => "Stop merging",
        "to" => ["AG2", "AG3"],
        "importance" => "urgent",
        "ack_required" => true
      })
      |> json_response(201)

      assert [~s(request 4 T1.1 from AG1 importance urgent ack "Freeze")] = lines(s, s.t2)
      assert [~s(request 4 T1.2 from AG1 importance urgent ack "Freeze")] = lines(s, s.t3)

      authed(s.t1)
      |> post(~p"/v1/threads/T1/messages", %{
        "kind" => "note",
        "body" => "Back at 3",
        "ack_required" => true,
        "to" => "AG3"
      })
      |> json_response(201)

      authed(s.t1)
      |> post(~p"/v1/threads/T1/messages", %{"kind" => "note", "body" => "fyi"})
      |> json_response(201)

      assert [~s(ack 5 T1.3 from AG1 "Freeze")] = lines(s, s.t3, 4)
      assert [] = lines(s, s.t2, 4)

      authed(s.t3) |> post(~p"/v1/threads/T1/ack", %{}) |> json_response(200)
      assert [] = lines(s, s.t1, 6)
    end

    test "a reservation wakes only its waiters, when it is released or expires", %{s: s} do
      reserve = fn token, patterns, status ->
        authed(token)
        |> post(~p"/v1/sessions/#{s.code}/reservations", %{"patterns" => patterns})
        |> json_response(status)
      end

      reserve.(s.t1, ["repo:c3/lib/**", "slot:deploy"], 201)
      reserve.(s.t2, ["repo:c3/lib/c3.ex"], 409)

      # Reserving and running into one wake nobody.
      for token <- [s.t1, s.t2, s.t3], do: assert({5, []} = watch(s, token, after: 3))

      authed(s.t1)
      |> post(~p"/v1/sessions/#{s.code}/reservations/release", %{"reservations" => ["R1"]})
      |> json_response(200)

      assert ["reservation_free 6 R1 repo:c3/lib/** released_by AG1"] = lines(s, s.t2, 5)
      assert [] = lines(s, s.t3, 5)
      assert [] = lines(s, s.t1, 5)

      reserve.(s.t3, ["slot:deploy"], 409)

      C3.Repo.update_all(where(C3.Reservations.Reservation, number: 2),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )

      assert C3.Reservations.expire() == 1
      assert ["reservation_free 7 R2 slot:deploy expired held_by AG1"] = lines(s, s.t3, 6)
      assert [] = lines(s, s.t2, 6)
    end

    test "is held through other agents' events until one concerns the caller", %{s: s} do
      task =
        Task.async(fn ->
          Process.sleep(100)
          open_thread(s, s.t1, ["AG2"], "Not yours")
          Process.sleep(200)
          open_thread(s, s.t1, ["AG3"], "Yours")
        end)

      started = System.monotonic_time(:millisecond)
      conn = watch_conn(s, s.t3, after: 3, wait: 10)
      ms = System.monotonic_time(:millisecond) - started
      Task.await(task)

      assert ["cursor " <> cursor, ~s(request ) <> line] =
               conn |> response(200) |> String.split("\n", trim: true)

      assert line =~ ~r/T2\.1 from AG1 "Yours"$/
      assert String.to_integer(cursor) > 4
      assert ms >= 300 and ms < 5_000
    end

    test "a join wakes the agent that created the session, nobody else", %{s: s} do
      assert {3, ["joined 2 AG2 label backend", "joined 3 AG3"]} = watch(s, s.t1, after: 0)
      assert {3, []} = watch(s, s.t2, after: 0)
      assert {3, []} = watch(s, s.t3, after: 0)
    end

    test "a failed join is a security line for everyone", %{s: s} do
      wrong = if s.secret == "000000", do: "111111", else: "000000"

      fresh_conn()
      |> post(~p"/v1/sessions/#{s.code}/join", %{"secret" => wrong})
      |> json_response(403)

      assert ["security 4 join_failed ip " <> _] = lines(s, s.t1)
      assert ["security 4 join_failed ip " <> _] = lines(s, s.t2)
    end

    test "the close of the session is a stop line; the next watch is 410", %{s: s} do
      authed(s.t1) |> post(~p"/v1/sessions/#{s.code}/close", %{}) |> json_response(200)

      # Closing revokes every token, the closer's too: only a watch in flight sees the stop line.
      assert watch_conn(s, s.t2, after: 3, wait: 0) |> response(410)
      assert watch_conn(s, s.t1, after: 3, wait: 0) |> response(410)
    end

    test "a close while waiting answers with the stop line", %{s: s} do
      task =
        Task.async(fn ->
          Process.sleep(100)
          authed(s.t1) |> post(~p"/v1/sessions/#{s.code}/close", %{})
        end)

      conn = watch_conn(s, s.t2, after: 3, wait: 10)
      Task.await(task)

      assert ["cursor 4", "stop 4 session_closed by AG1 reason manual"] =
               conn |> response(200) |> String.split("\n", trim: true)
    end

    test "the title is one line, without double quotes, cut to 80 characters", %{s: s} do
      title = ~s(Say "hi"\n\tthen ) <> String.duplicate("x", 100)
      open_thread(s, s.t1, ["AG2"], title)

      assert [line] = lines(s, s.t2)
      assert [_, quoted] = String.split(line, " \"", parts: 2)
      assert quoted == "Say 'hi' then " <> String.duplicate("x", 66) <> "\""
    end

    test "rejects a bad cursor and a missing token", %{s: s} do
      assert watch_conn(s, s.t1, after: -1) |> json_response(422)
      assert fresh_conn() |> get(~p"/v1/sessions/#{s.code}/watch") |> json_response(401)
    end
  end

  describe "message.posted" do
    test "a response says whose requests it resolved", %{s: s} do
      open_thread(s, s.t1, ["AG2"])

      authed(s.t2)
      |> post(~p"/v1/threads/T1/messages", %{"kind" => "response", "body" => "Done"})
      |> json_response(201)

      %{"events" => events} =
        authed(s.t1) |> get(~p"/v1/sessions/#{s.code}/events?after=3") |> json_response(200)

      assert %{"payload" => %{"resolved" => ["T1.1"], "resolved_for" => ["AG1"]}} =
               Enum.find(events, &(&1["type"] == "message.posted"))
    end
  end
end
