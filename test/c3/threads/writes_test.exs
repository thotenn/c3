defmodule C3.Threads.WritesTest do
  use C3.DataCase

  import C3.Fixtures

  alias C3.{Events, Sessions, Threads}
  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.{Message, Thread}

  setup do
    session = session_fixture()
    ag1 = agent_fixture(session, %{number: 1})
    ag2 = agent_fixture(session, %{number: 2, label: "backend"})
    ag3 = agent_fixture(session, %{number: 3, label: "backend"})
    ag4 = agent_fixture(session, %{number: 4, label: "qa"})
    %{session: session, ag1: ag1, ag2: ag2, ag3: ag3, ag4: ag4}
  end

  defp open!(author, to, title \\ "Need help") do
    {:ok, thread} =
      Threads.open_thread(author, %{"title" => title, "body" => "Do it", "to" => to})

    thread
  end

  defp post(author, thread, attrs) do
    Threads.post_message(author, thread, Map.merge(%{"body" => "Here"}, attrs))
  end

  defp reply!(author, thread, reply_to \\ nil) do
    {:ok, posted} = post(author, thread, %{"kind" => "response", "reply_to" => reply_to})
    posted
  end

  # The cached status always equals the derived one; returns the derived state.
  defp state!(thread) do
    thread = Repo.reload!(thread)
    state = Threads.state(thread)
    assert thread.status == state.status, "threads.status drifted from the derivation"
    state
  end

  defp request(thread, number), do: Repo.get_by!(Message, thread_id: thread.id, number: number)

  defp types(session), do: session |> Events.list_after(0) |> Enum.map(& &1.type)

  describe "open_thread/2" do
    test "to one agent: T1 with request T1.1, pending on it",
         %{session: session, ag1: ag1, ag2: ag2} do
      thread = open!(ag1, "AG2")

      assert {thread.number, thread.status} == {1, :pending}
      assert %{status: :pending, awaiting: ["AG2"], processing_by: []} = state!(thread)

      assert %Message{kind: :request, request_state: :open, to_target: :agent} =
               request(thread, 1)

      assert request(thread, 1).to_agent_id == ag2.id

      assert [%{type: :thread_opened, payload: payload}] = Events.list_after(session, 0)

      assert payload == %{
               "thread" => "T1",
               "title" => "Need help",
               "opened_by" => "AG1",
               "to" => ["AG2"],
               "requests" => ["T1.1"]
             }
    end

    test "a list makes one request per target, duplicates dropped", %{ag1: ag1} do
      thread = open!(ag1, ["AG2", "ag3", "AG2", "label:qa"])
      assert state!(thread).awaiting == ["AG2", "AG3", "label:qa"]
      assert Repo.aggregate(where(Message, thread_id: ^thread.id), :count) == 3
    end

    test "to omitted means any", %{ag1: ag1} do
      thread = open!(ag1, nil)
      assert state!(thread).awaiting == ["any"]
    end

    test "numbers threads per session", %{ag1: ag1} do
      assert open!(ag1, "AG2").number == 1
      assert open!(ag1, "AG2").number == 2
    end

    test "an unknown, absent, own or malformed target is a 422", %{ag1: ag1, session: session} do
      agent_fixture(session, %{number: 5, status: :left, left_at: DateTime.utc_now()})

      for to <- ["AG9", "AG5", "AG1", "nobody", "label:Bad Label", [], ["AG2", 7]] do
        assert {:error, {:invalid, _message, %{to: _}}} =
                 Threads.open_thread(ag1, %{"title" => "t", "body" => "b", "to" => to}),
               "to=#{inspect(to)} was accepted"
      end

      assert Repo.aggregate(Thread, :count) == 0
    end

    test "an invalid title rolls back, thread number included", %{ag1: ag1, session: session} do
      assert {:error, %Ecto.Changeset{}} =
               Threads.open_thread(ag1, %{"title" => "", "body" => "b", "to" => "AG2"})

      assert Repo.reload!(session).next_thread_number == 1
      assert types(session) == []
    end

    test "a body over the limit is too_large", %{ag1: ag1} do
      body = String.duplicate("x", Message.max_body_bytes() + 1)

      assert {:error, {:too_large, _}} =
               Threads.open_thread(ag1, %{"title" => "t", "body" => body, "to" => "AG2"})
    end
  end

  describe "responses" do
    test "one request per target: awaiting shrinks as each one answers",
         %{ag1: ag1, ag2: ag2, ag3: ag3} do
      thread = open!(ag1, ["AG2", "AG3"])

      posted = reply!(ag2, thread)
      assert posted.resolved == ["T1.1"]
      assert hd(posted.messages).reply_to_message_id == request(thread, 1).id
      assert %{status: :pending, awaiting: ["AG3"]} = state!(thread)

      reply!(ag3, thread, "T1.2")
      assert %{status: :answered, awaiting: []} = state!(thread)

      assert %Message{request_state: :done, claimed_by_agent_id: id, resolved_at: %DateTime{}} =
               request(thread, 1)

      assert id == ag2.id
    end

    test "label: is resolved by the first holder that answers", %{ag1: ag1, ag2: ag2, ag3: ag3} do
      thread = open!(ag1, "label:backend")
      reply!(ag3, thread)
      assert state!(thread).status == :answered

      assert {:error, {:conflict, "T1.1 is already done", _}} =
               post(ag2, thread, %{"kind" => "response", "reply_to" => "T1.1"})
    end

    test "any is for anyone but its author", %{ag1: ag1, ag4: ag4} do
      thread = open!(ag1, "any")

      assert {:error, {:forbidden, _}} =
               post(ag1, thread, %{"kind" => "response", "reply_to" => "1"})

      # Without reply_to the author's response resolves nothing.
      assert %{resolved: []} = reply!(ag1, thread)
      assert state!(thread).status == :pending

      assert %{resolved: ["T1.1"]} = reply!(ag4, thread)
      assert state!(thread).status == :answered
    end

    test "replying to a request addressed to someone else is forbidden",
         %{ag1: ag1, ag3: ag3} do
      thread = open!(ag1, "AG2")

      assert {:error, {:forbidden, "T1.1 is not addressed to you"}} =
               post(ag3, thread, %{"kind" => "response", "reply_to" => "T1.1"})
    end

    test "a request claimed by someone else cannot be answered", %{ag1: ag1, ag2: ag2, ag3: ag3} do
      thread = open!(ag1, "any")
      {:ok, _} = Threads.claim(ag2, thread, %{})

      assert {:error, {:conflict, "T1.1 is claimed by AG2", %{claimed_by: %{"T1.1" => "AG2"}}}} =
               post(ag3, thread, %{"kind" => "response", "reply_to" => "T1.1"})

      # Without reply_to, AG3 has nothing to resolve.
      assert %{resolved: []} = reply!(ag3, thread)
      assert %{resolved: ["T1.1"]} = reply!(ag2, thread)
    end

    test "a new request on an answered thread makes it pending again",
         %{ag1: ag1, ag2: ag2, session: session} do
      thread = open!(ag1, "AG2")
      reply!(ag2, thread)

      {:ok, posted} = post(ag2, thread, %{"kind" => "request", "to" => "AG1"})
      assert [%Message{number: 3, to_agent_id: id}] = posted.messages
      assert id == ag1.id
      assert %{status: :pending, awaiting: ["AG1"]} = state!(thread)

      assert types(session) == [
               :thread_opened,
               :message_posted,
               :thread_status_changed,
               :message_posted,
               :thread_status_changed
             ]
    end

    test "a note changes nothing and takes no to", %{ag1: ag1, ag3: ag3, session: session} do
      thread = open!(ag1, "AG2")
      assert {:ok, %{resolved: []}} = post(ag3, thread, %{"kind" => "note"})
      assert state!(thread).status == :pending
      assert List.last(types(session)) == :message_posted

      assert {:error, {:invalid, _, _}} = post(ag3, thread, %{"kind" => "note", "to" => "AG1"})
      assert {:error, {:invalid, _, _}} = post(ag3, thread, %{"kind" => "system"})
    end

    test "reply_to must be a message of this thread", %{ag1: ag1, ag2: ag2} do
      thread = open!(ag1, "AG2")

      assert {:error, {:invalid, _, _}} =
               post(ag2, thread, %{"kind" => "note", "reply_to" => "T9.1"})

      assert {:error, {:invalid, _, _}} =
               post(ag2, thread, %{"kind" => "note", "reply_to" => "7"})

      assert {:error, {:invalid, _, _}} =
               post(ag2, thread, %{"kind" => "note", "reply_to" => "x"})
    end

    test "the message.posted payload says what it resolved", %{
      ag1: ag1,
      ag2: ag2,
      session: session
    } do
      thread = open!(ag1, "AG2")
      reply!(ag2, thread)

      assert %{payload: payload} =
               Enum.find(Events.list_after(session, 0), &(&1.type == :message_posted))

      assert payload == %{
               "thread" => "T1",
               "message" => "T1.2",
               "kind" => "response",
               "author" => "AG2",
               "to" => nil,
               "reply_to" => "T1.1",
               "resolved" => ["T1.1"]
             }
    end
  end

  describe "claim/3" do
    test "claims the requests addressed to me; again is a no-op",
         %{ag1: ag1, ag2: ag2, session: session} do
      thread = open!(ag1, ["AG2", "AG3"])

      assert {:ok, %{claimed: ["T1.1"]}} = Threads.claim(ag2, thread, %{})
      assert %{status: :pending, awaiting: ["AG3"], processing_by: ["AG2"]} = state!(thread)

      assert {:ok, %{claimed: ["T1.1"]}} = Threads.claim(ag2, thread, %{"request_id" => "T1.1"})
      assert Enum.count(types(session), &(&1 == :request_claimed)) == 1
    end

    test "claimed only → processing; answering it → answered", %{ag1: ag1, ag2: ag2} do
      thread = open!(ag1, "AG2")
      {:ok, _} = Threads.claim(ag2, thread, %{})
      assert %{status: :processing, processing_by: ["AG2"]} = state!(thread)

      reply!(ag2, thread)
      assert state!(thread).status == :answered
      assert %Message{request_state: :done, claimed_by_agent_id: id} = request(thread, 1)
      assert id == ag2.id
    end

    test "a request held by someone else is a 409 that says who", %{ag1: ag1, ag2: ag2, ag3: ag3} do
      thread = open!(ag1, "label:backend")
      {:ok, _} = Threads.claim(ag2, thread, %{})

      assert {:error, {:conflict, _, %{claimed_by: %{"T1.1" => "AG2"}}}} =
               Threads.claim(ag3, thread, %{})

      assert {:error, {:conflict, "T1.1 is claimed by AG2", _}} =
               Threads.claim(ag3, thread, %{"request_id" => "T1.1"})
    end

    test "nothing addressed to me is a 409; a request to someone else is a 403",
         %{ag1: ag1, ag4: ag4} do
      thread = open!(ag1, "AG2")
      assert {:error, {:conflict, _, %{claimed_by: %{}}}} = Threads.claim(ag4, thread, %{})

      assert {:error, {:forbidden, _}} = Threads.claim(ag4, thread, %{"request_id" => "T1.1"})
    end

    test "only requests can be claimed", %{ag1: ag1, ag2: ag2} do
      thread = open!(ag1, "AG2")
      {:ok, _} = post(ag1, thread, %{"kind" => "note"})

      assert {:error, {:invalid, "T1.2 is not a request", _}} =
               Threads.claim(ag2, thread, %{"request_id" => "2"})
    end

    test "racing for an any request: exactly one wins", %{session: session, ag1: ag1} do
      racers = for n <- 10..17, do: agent_fixture(session, %{number: n})
      thread = open!(ag1, "any")

      results =
        racers
        |> Task.async_stream(&Threads.claim(&1, thread, %{}), max_concurrency: length(racers))
        |> Enum.map(fn {:ok, result} -> result end)

      assert [{:ok, %{claimed: ["T1.1"]}}] = Enum.filter(results, &match?({:ok, _}, &1))
      losers = Enum.filter(results, &match?({:error, _}, &1))
      assert length(losers) == length(racers) - 1

      winner = Repo.get!(Agent, request(thread, 1).claimed_by_agent_id).name

      for {:error, {:conflict, _, %{claimed_by: holders}}} <- losers do
        assert holders == %{"T1.1" => winner}
      end

      assert Enum.count(types(session), &(&1 == :request_claimed)) == 1
      assert state!(thread).processing_by == [winner]
    end

    test "racing for a named request and its answer: the request ends done once",
         %{ag1: ag1, ag2: ag2} do
      thread = open!(ag1, "AG2")

      [claim, answer] =
        [fn -> Threads.claim(ag2, thread, %{}) end, fn -> reply!(ag2, thread) end]
        |> Enum.map(&Task.async/1)
        |> Enum.map(&Task.await/1)

      assert match?({:ok, _}, claim) or match?({:error, {:conflict, _, _}}, claim)
      assert %{resolved: ["T1.1"]} = answer
      assert %Message{request_state: :done} = request(thread, 1)
      assert state!(thread).status == :answered
    end
  end

  describe "cancel/3" do
    defp cancel(agent, thread, ref, attrs \\ %{}),
      do: Threads.cancel(agent, thread, Map.put(attrs, "request_id", ref))

    test "the author cancels an open request; the thread is derived again",
         %{ag1: ag1, ag2: ag2, session: session} do
      thread = open!(ag1, ["AG2", "AG3"])

      assert {:ok, %{cancelled: "T1.2", note: nil}} = cancel(ag1, thread, "T1.2")
      assert %{status: :pending, awaiting: ["AG2"]} = state!(thread)

      assert %Message{request_state: :cancelled, resolved_at: %DateTime{}} = request(thread, 2)

      assert %{type: :request_cancelled, message_id: mid, payload: payload} =
               session |> Events.list_after(0) |> Enum.find(&(&1.type == :request_cancelled))

      assert mid == request(thread, 2).id

      assert payload == %{
               "thread" => "T1",
               "request" => "T1.2",
               "author" => "AG1",
               "to" => "AG3",
               "cancelled_by" => "AG1",
               "claimed_by" => nil,
               "reason" => nil
             }

      assert {:ok, _} = cancel(ag1, thread, "1")
      assert state!(thread).status == :answered
      refute Enum.any?(Threads.inbox(ag2))
    end

    test "a claimed request: the holder learns it, with the reason, and cannot answer it",
         %{ag1: ag1, ag2: ag2} do
      thread = open!(ag1, "AG2")
      {:ok, _} = Threads.claim(ag2, thread, %{})

      assert {:ok, %{cancelled: "T1.1", note: "T1.2"}} =
               cancel(ag1, thread, "T1.1", %{"reason" => "Wrong agent, sorry"})

      assert %{status: :answered, processing_by: []} = state!(thread)

      assert %Message{kind: :note, body: "Wrong agent, sorry", reply_to_message_id: rid} =
               request(thread, 2)

      assert rid == request(thread, 1).id

      assert [
               %{
                 type: :request_cancelled,
                 payload: %{"claimed_by" => "AG2", "reason" => "Wrong agent, sorry"}
               }
             ] =
               Sessions.take_notices(ag2)

      assert {:error, {:conflict, "T1.1 is already cancelled", _}} =
               post(ag2, thread, %{"kind" => "response", "reply_to" => "T1.1"})

      assert {:error, {:conflict, _, _}} = Threads.claim(ag2, thread, %{"request_id" => "T1.1"})
    end

    test "the author or opened_by may cancel; nobody else", %{ag1: ag1, ag2: ag2, ag3: ag3} do
      thread = open!(ag1, "AG2")
      {:ok, _} = post(ag2, thread, %{"kind" => "request", "to" => "AG3"})

      assert {:error, {:forbidden, _}} = cancel(ag3, thread, "T1.2")
      assert {:error, {:forbidden, _}} = cancel(ag2, thread, "T1.1")
      assert {:ok, _} = cancel(ag1, thread, "T1.2")
      assert {:ok, _} = Threads.cancel(ag1, thread, %{"request_id" => "T1.1"})
    end

    test "a request already answered is a 409; bad input is a 422", %{ag1: ag1, ag2: ag2} do
      thread = open!(ag1, "AG2")
      reply!(ag2, thread)

      assert {:error, {:conflict, "T1.1 is already done", _}} = cancel(ag1, thread, "T1.1")
      assert {:error, {:invalid, "T1.2 is not a request", _}} = cancel(ag1, thread, "T1.2")
      assert {:error, {:invalid, _, _}} = Threads.cancel(ag1, thread, %{})
      assert {:error, {:invalid, _, _}} = cancel(ag1, thread, "T1.1", %{"reason" => 42})

      big = String.duplicate("x", Message.max_body_bytes() + 1)
      assert {:error, {:too_large, _}} = cancel(ag1, thread, "T1.1", %{"reason" => big})
    end

    test "the notice reaches whoever could have taken the request, not its canceller",
         %{ag1: ag1, ag2: ag2, ag3: ag3, ag4: ag4} do
      labelled = open!(ag1, "label:backend")
      anyone = open!(ag2, "any")
      {:ok, _} = cancel(ag1, labelled, "T1.1")
      {:ok, _} = cancel(ag2, anyone, "T2.1")

      requests = fn agent ->
        agent |> Sessions.take_notices() |> Enum.map(& &1.payload["request"])
      end

      assert requests.(ag1) == ["T2.1"]
      assert requests.(ag2) == ["T1.1"]
      assert requests.(ag3) == ["T1.1", "T2.1"]
      assert requests.(ag4) == ["T2.1"]
      assert requests.(Repo.reload!(ag3)) == []
    end
  end

  describe "finish/3 and reopen/2" do
    test "only opened_by", %{ag1: ag1, ag2: ag2} do
      thread = open!(ag1, "AG2")
      assert {:error, {:forbidden, _}} = Threads.finish(ag2, thread, %{"force" => true})
      assert {:error, {:forbidden, _}} = Threads.reopen(ag2, thread)
    end

    test "with pending requests: 409 unless force, which cancels them",
         %{ag1: ag1, ag2: ag2, session: session} do
      thread = open!(ag1, ["AG2", "AG3"])
      {:ok, _} = Threads.claim(ag2, thread, %{})

      assert {:error, {:conflict, _, %{pending: ["T1.1", "T1.2"]}}} =
               Threads.finish(ag1, thread, %{})

      assert state!(thread).status == :pending

      assert {:ok, %{changed: true, cancelled: ["T1.1", "T1.2"]}} =
               Threads.finish(ag1, thread, %{"force" => "true"})

      assert %{status: :finished, awaiting: [], processing_by: []} = state!(thread)
      assert Repo.reload!(thread).finished_at

      assert %Message{request_state: :cancelled, claimed_by_agent_id: nil} = request(thread, 1)

      assert %{payload: %{"to" => "finished", "cancelled" => ["T1.1", "T1.2"]}} =
               session |> Events.list_after(0) |> List.last()
    end

    test "a finished thread takes no posts or claims; finishing again is a no-op",
         %{ag1: ag1, ag2: ag2, session: session} do
      thread = open!(ag1, "AG2")
      reply!(ag2, thread)
      assert {:ok, %{changed: true, cancelled: []}} = Threads.finish(ag1, thread, %{})

      assert {:error, {:conflict, "T1 is finished; reopen it first", _}} =
               post(ag2, thread, %{"kind" => "note"})

      assert {:error, {:conflict, _, _}} = Threads.claim(ag2, thread, %{})

      before = types(session)
      assert {:ok, %{changed: false}} = Threads.finish(ag1, thread, %{})
      assert types(session) == before
    end

    test "reopen derives the status again", %{ag1: ag1, ag2: ag2} do
      thread = open!(ag1, "AG2")
      reply!(ag2, thread)
      {:ok, _} = Threads.finish(ag1, thread, %{})

      assert {:ok, %{changed: true}} = Threads.reopen(ag1, thread)
      assert %{status: :answered} = state!(thread)
      refute Repo.reload!(thread).finished_at

      assert {:ok, %{changed: false}} = Threads.reopen(ag1, thread)
      {:ok, _} = post(ag1, thread, %{"kind" => "request", "to" => "AG2"})
      assert state!(thread).status == :pending
    end
  end

  describe "leave" do
    test "the released claims recompute their threads in the same transaction",
         %{ag1: ag1, ag2: ag2, session: session} do
      thread = open!(ag1, "any")
      other = open!(ag1, "AG2")
      {:ok, _} = Threads.claim(ag2, thread, %{})
      {:ok, _} = Threads.claim(ag2, other, %{})
      assert state!(thread).status == :processing

      assert {:ok, ["T1.1", "T2.1"]} = Sessions.leave(ag2)

      assert %{status: :pending, awaiting: ["any"], processing_by: []} = state!(thread)
      # Still addressed to AG2, who left: it waits for them (or for a forced finish).
      assert %{status: :pending, awaiting: ["AG2"]} = state!(other)

      assert Enum.take(types(session), -3) ==
               [:agent_left, :thread_status_changed, :thread_status_changed]
    end
  end

  describe "expire_claims/1" do
    test "a claim whose agent went silent goes back to open", %{ag1: ag1, ag2: ag2, ag3: ag3} do
      thread = open!(ag1, "label:backend")
      fresh = open!(ag1, "AG3")
      {:ok, _} = Threads.claim(ag2, thread, %{})
      {:ok, _} = Threads.claim(ag3, fresh, %{})

      now = DateTime.utc_now()
      old = DateTime.add(now, -C3.Config.get(:claim_ttl) - 60)
      Repo.update_all(where(Agent, id: ^ag2.id), set: [last_seen_at: old])
      Repo.update_all(where(Message, thread_id: ^thread.id), set: [claimed_at: old])

      assert Threads.expire_claims(now) == 1

      assert %Message{request_state: :open, claimed_by_agent_id: nil} = request(thread, 1)
      assert %{status: :pending, awaiting: ["label:backend"]} = state!(thread)
      assert state!(fresh).status == :processing

      session = %Session{id: thread.session_id}

      assert [%{payload: %{"request" => "T1.1", "claimed_by" => "AG2"}, thread_id: tid}] =
               session
               |> Events.list_after(0)
               |> Enum.filter(&(&1.type == :request_claim_expired))

      assert tid == thread.id
      assert Threads.expire_claims(now) == 0
    end

    test "a silent agent whose claim is recent keeps it", %{ag1: ag1, ag2: ag2} do
      thread = open!(ag1, "AG2")
      {:ok, _} = Threads.claim(ag2, thread, %{})
      old = DateTime.add(DateTime.utc_now(), -C3.Config.get(:claim_ttl) - 60)
      Repo.update_all(where(Agent, id: ^ag2.id), set: [last_seen_at: old])

      assert Threads.expire_claims() == 0
    end
  end

  describe "inbox/1" do
    test "open requests to me, my label or any from others, plus what I claimed",
         %{ag1: ag1, ag2: ag2, ag3: ag3} do
      t1 = open!(ag1, "AG2")
      _t2 = open!(ag1, "AG3")
      t3 = open!(ag1, "label:backend")
      t4 = open!(ag2, "any")
      t5 = open!(ag1, "any")
      {:ok, _} = Threads.claim(ag3, t5, %{})
      t6 = open!(ag1, "AG2")
      {:ok, _} = Threads.claim(ag2, t6, %{})
      t7 = open!(ag1, "AG2")
      reply!(ag2, t7)

      assert [{%Thread{} = first, [%Message{}]} | _] = groups = Threads.inbox(ag2)
      assert first.opened_by_agent.name == "AG1"
      assert Enum.map(groups, fn {t, _} -> t.id end) == [t1.id, t3.id, t6.id]
      refute t4.id in Enum.map(groups, fn {t, _} -> t.id end)

      assert Enum.map(Threads.inbox(ag1), fn {t, _} -> t.id end) == [t4.id]
    end
  end

  describe "Sessions.take_notices/1 and touch_seen/2" do
    test "alerts show once", %{session: session, ag2: ag2} do
      Repo.transaction(fn ->
        Events.append!(session, :agent_joined)
        Events.append!(session, :security_join_failed, payload: %{ip: "198.51.100.9"})
      end)

      assert [%{type: :security_join_failed, seq: 2}] = Sessions.take_notices(ag2)
      assert Sessions.take_notices(Repo.reload!(ag2)) == []
    end

    test "last_seen_at is written at most once per throttle", %{ag2: ag2} do
      now = DateTime.utc_now()
      assert Sessions.touch_seen(ag2, DateTime.add(ag2.last_seen_at, 5)) == ag2

      later = DateTime.add(now, 120)
      assert Sessions.touch_seen(ag2, later).last_seen_at == later
      assert Repo.reload!(ag2).last_seen_at == later
    end
  end
end
