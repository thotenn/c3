defmodule C3.Threads.AcksTest do
  use C3.DataCase

  import C3.Fixtures

  alias C3.Events.Event
  alias C3.Threads
  alias C3.Threads.{Acks, Message, MessageAck}

  setup do
    session = session_fixture()
    ag1 = agent_fixture(session, %{number: 1})
    ag2 = agent_fixture(session, %{number: 2, label: "backend"})
    ag3 = agent_fixture(session, %{number: 3, label: "backend"})
    %{session: session, ag1: ag1, ag2: ag2, ag3: ag3}
  end

  defp open(author, attrs) do
    {:ok, thread} =
      Threads.open_thread(author, Map.merge(%{"title" => "Freeze", "body" => "Stop"}, attrs))

    thread
  end

  defp post(author, thread, attrs), do: Threads.post_message(author, thread, attrs)

  defp asked(message_number, thread) do
    MessageAck
    |> join(:inner, [k], m in Message, on: m.id == k.message_id)
    |> join(:inner, [k], a in assoc(k, :agent))
    |> where([k, m], m.thread_id == ^thread.id and m.number == ^message_number)
    |> order_by([k, m, a], a.number)
    |> select([k, m, a], {a.name, not is_nil(k.acked_at)})
    |> Repo.all()
  end

  defp last_event(session) do
    Event |> where(session_id: ^session.id) |> order_by(desc: :seq) |> limit(1) |> Repo.one!()
  end

  defp payload_of(session, type) do
    Event
    |> where(session_id: ^session.id, type: ^type)
    |> order_by(desc: :seq)
    |> limit(1)
    |> Repo.one!()
    |> Map.fetch!(:payload)
  end

  describe "importance and ack_required" do
    test "default to normal and no ack, and are stored on requests and notes", ctx do
      t = open(ctx.ag1, %{"to" => "AG2"})

      assert %Message{importance: :normal, ack_required: false} =
               Repo.get_by!(Message, thread_id: t.id)

      assert asked(1, t) == []

      t2 = open(ctx.ag1, %{"to" => "AG2", "importance" => "urgent", "ack_required" => true})

      assert %Message{importance: :urgent, ack_required: true} =
               Repo.get_by!(Message, thread_id: t2.id)

      assert %{"importance" => "urgent", "ack_from" => ["AG2"]} =
               payload_of(ctx.session, :thread_opened)
    end

    test "a plain message keeps the payloads it had", ctx do
      t = open(ctx.ag1, %{"to" => "AG2"})
      refute Map.has_key?(payload_of(ctx.session, :thread_opened), "importance")
      {:ok, _} = post(ctx.ag1, t, %{"kind" => "note", "body" => "fyi"})
      payload = payload_of(ctx.session, :message_posted)
      refute Map.has_key?(payload, "importance") or Map.has_key?(payload, "ack_from")
    end

    test "a response takes neither; bad values are a 422", ctx do
      t = open(ctx.ag1, %{"to" => "AG2"})

      for attrs <- [%{"importance" => "high"}, %{"ack_required" => true}] do
        assert {:error, {:invalid, _, %{importance: _}}} =
                 post(ctx.ag2, t, Map.merge(%{"kind" => "response", "body" => "ok"}, attrs))
      end

      assert {:error, {:invalid, _, %{importance: _}}} =
               post(ctx.ag1, t, %{"kind" => "note", "body" => "x", "importance" => "panic"})

      assert {:error, {:invalid, _, %{ack_required: _}}} =
               post(ctx.ag1, t, %{"kind" => "note", "body" => "x", "ack_required" => "yes"})
    end
  end

  describe "who is asked" do
    test "a request asks its target: the agent, the label holders, or everyone else", ctx do
      t = open(ctx.ag1, %{"to" => ["AG2", "label:backend", "any"], "ack_required" => true})

      assert asked(1, t) == [{"AG2", false}]
      assert asked(2, t) == [{"AG2", false}, {"AG3", false}]
      assert asked(3, t) == [{"AG2", false}, {"AG3", false}]
    end

    test "a note asks its to, everyone else by default; without ack it takes no to", ctx do
      t = open(ctx.ag1, %{"to" => "AG2"})

      {:ok, _} = post(ctx.ag1, t, %{"kind" => "note", "body" => "a", "ack_required" => true})
      assert asked(2, t) == [{"AG2", false}, {"AG3", false}]
      assert %{"ack_from" => ["AG2", "AG3"]} = payload_of(ctx.session, :message_posted)

      {:ok, _} =
        post(ctx.ag1, t, %{"kind" => "note", "body" => "b", "ack_required" => true, "to" => "AG3"})

      assert asked(3, t) == [{"AG3", false}]

      assert {:error, {:invalid, _, _}} =
               post(ctx.ag1, t, %{"kind" => "note", "body" => "c", "to" => "AG3"})
    end

    test "an agent that left is not asked", ctx do
      {:ok, _} = C3.Sessions.leave(ctx.ag3)
      t = open(ctx.ag1, %{"to" => "any", "ack_required" => true})
      assert asked(1, t) == [{"AG2", false}]
    end
  end

  describe "Threads.ack/3" do
    setup ctx do
      t = open(ctx.ag1, %{"to" => "AG2", "ack_required" => true})

      {:ok, _} =
        post(ctx.ag1, t, %{"kind" => "note", "body" => "b", "ack_required" => true, "to" => "AG2"})

      %{t: t}
    end

    test "one message, with message.acked; the request stays open", ctx do
      assert {:ok, %{acked: ["T1.2"]}} = Threads.ack(ctx.ag2, ctx.t, %{"message" => "T1.2"})
      assert asked(2, ctx.t) == [{"AG2", true}]
      assert asked(1, ctx.t) == [{"AG2", false}]

      assert %Event{
               type: :message_acked,
               payload: %{"message" => "T1.2", "by" => "AG2", "author" => "AG1"}
             } =
               last_event(ctx.session)

      assert %Message{request_state: :open} =
               Repo.get_by!(Message, thread_id: ctx.t.id, number: 1)
    end

    test "every pending one; again is a 409, one already acked a no-op", ctx do
      assert {:ok, %{acked: ["T1.1", "T1.2"]}} = Threads.ack(ctx.ag2, ctx.t, %{})
      assert {:error, {:conflict, _, _}} = Threads.ack(ctx.ag2, ctx.t, %{})

      seq = last_event(ctx.session).seq
      assert {:ok, %{acked: ["T1.1"]}} = Threads.ack(ctx.ag2, ctx.t, %{"message" => "1"})
      assert last_event(ctx.session).seq == seq
    end

    test "a message that did not ask me is a 409; one that does not exist a 422", ctx do
      assert {:error, {:conflict, _, _}} = Threads.ack(ctx.ag3, ctx.t, %{"message" => "T1.2"})
      assert {:error, {:invalid, _, _}} = Threads.ack(ctx.ag2, ctx.t, %{"message" => "T1.9"})
    end

    test "claiming or answering a request acknowledges it", ctx do
      {:ok, _} = Threads.claim(ctx.ag2, ctx.t, %{})
      assert asked(1, ctx.t) == [{"AG2", true}]

      t2 = open(ctx.ag1, %{"to" => "AG2", "ack_required" => true})
      {:ok, _} = post(ctx.ag2, t2, %{"kind" => "response", "body" => "done"})
      assert asked(1, t2) == [{"AG2", true}]
    end
  end

  describe "pending/2" do
    test "what is left to acknowledge, without what the caller excludes", ctx do
      t = open(ctx.ag1, %{"to" => "AG2", "ack_required" => true, "importance" => "high"})
      {:ok, _} = post(ctx.ag1, t, %{"kind" => "note", "body" => "b", "ack_required" => true})

      assert [%Message{number: 1}, %Message{number: 2}] = Acks.pending(ctx.ag2)
      [request | _] = Acks.pending(ctx.ag2)
      assert [%Message{number: 2}] = Acks.pending(ctx.ag2, [request.id])
      assert [%Message{number: 2}] = Acks.pending(ctx.ag3)
    end
  end
end
