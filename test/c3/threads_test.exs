defmodule C3.ThreadsTest do
  use C3.DataCase

  import C3.Fixtures

  alias C3.Threads
  alias C3.Threads.{Message, Thread}

  setup do
    session = session_fixture()
    ag1 = agent_fixture(session, %{number: 1})
    ag2 = agent_fixture(session, %{number: 2})
    %{session: session, ag1: ag1, ag2: ag2, thread: thread_fixture(ag1, %{number: 1})}
  end

  describe "Thread.changeset/2" do
    test "defaults to pending, lock_version 1", %{thread: thread} do
      assert thread.status == :pending
      assert thread.lock_version == 1
      assert %DateTime{} = thread.last_message_at
    end

    test "title is required and at most 200 characters" do
      assert "can't be blank" in errors_on(Thread.changeset(%Thread{}, %{})).title
      cs = Thread.changeset(%Thread{}, %{title: String.duplicate("t", 201)})
      assert "should be at most 200 character(s)" in errors_on(cs).title
    end

    test "finished_at is set exactly when finished" do
      assert errors_on(Thread.changeset(%Thread{}, %{status: :finished})).finished_at

      assert errors_on(Thread.changeset(%Thread{}, %{finished_at: DateTime.utc_now()})).finished_at

      refute Map.has_key?(
               errors_on(
                 Thread.changeset(%Thread{}, %{status: :finished, finished_at: DateTime.utc_now()})
               ),
               :finished_at
             )
    end

    test "number is unique per session", %{ag1: ag1} do
      assert {:error, cs} =
               %Thread{session_id: ag1.session_id, opened_by_agent_id: ag1.id}
               |> Thread.changeset(%{number: 1, title: "dup"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(cs).session_id
    end
  end

  describe "Message.changeset/2" do
    defp errors(thread, author, fields, attrs) do
      thread
      |> message_struct(author, fields)
      |> Message.changeset(Enum.into(attrs, %{number: 1, body: "b"}))
      |> errors_on()
    end

    test "a request to an agent is valid", %{thread: thread, ag1: ag1, ag2: ag2} do
      message = request_fixture(thread, ag1, ag2)
      assert {message.kind, message.to_target, message.request_state} == {:request, :agent, :open}
    end

    test "requests to a label and to any are valid", %{thread: thread, ag1: ag1} do
      for attrs <- [%{to_target: :label, to_label: "backend"}, %{to_target: :any}] do
        assert %Message{} =
                 thread
                 |> message_struct(ag1)
                 |> Message.changeset(
                   Enum.into(attrs, %{
                     number: unique_int(),
                     kind: :request,
                     body: "b",
                     request_state: :open
                   })
                 )
                 |> Repo.insert!()
      end
    end

    test "only system messages have no author", %{thread: thread, ag1: ag1} do
      assert errors(thread, nil, [], %{kind: :note}).author_agent_id
      assert errors(thread, ag1, [], %{kind: :system}).author_agent_id
      refute Map.has_key?(errors(thread, nil, [], %{kind: :system}), :author_agent_id)
    end

    test "to_target and request_state exactly for requests", %{thread: thread, ag1: ag1} do
      errs = errors(thread, ag1, [], %{kind: :request})
      assert errs.to_target
      assert errs.request_state

      errs = errors(thread, ag1, [], %{kind: :note, to_target: :any, request_state: :open})
      assert errs.to_target
      assert errs.request_state
    end

    test "the target column matches to_target", %{thread: thread, ag1: ag1, ag2: ag2} do
      base = %{kind: :request, request_state: :open}

      assert errors(thread, ag1, [], Map.put(base, :to_target, :agent)).to_agent_id
      assert errors(thread, ag1, [], Map.put(base, :to_target, :label)).to_label

      errs =
        errors(
          thread,
          ag1,
          [to_agent_id: ag2.id],
          Map.merge(base, %{to_target: :any, to_label: "x"})
        )

      assert errs.to_agent_id
      assert errs.to_label
    end

    test "to_label follows the agent label format", %{thread: thread, ag1: ag1} do
      attrs = %{kind: :request, request_state: :open, to_target: :label, to_label: "Not Valid"}
      assert "has invalid format" in errors(thread, ag1, [], attrs).to_label
    end

    test "claimed_by is set when claimed, optional when done, blank otherwise",
         %{thread: thread, ag1: ag1, ag2: ag2} do
      base = %{kind: :request, to_target: :any}
      claimed = [claimed_by_agent_id: ag2.id]

      assert errors(thread, ag1, [], Map.put(base, :request_state, :claimed)).claimed_by_agent_id

      for state <- [:open, :cancelled] do
        assert errors(thread, ag1, claimed, Map.put(base, :request_state, state)).claimed_by_agent_id
      end

      for {fields, state} <- [{claimed, :claimed}, {claimed, :done}, {[], :done}] do
        refute Map.has_key?(
                 errors(thread, ag1, fields, Map.put(base, :request_state, state)),
                 :claimed_by_agent_id
               )
      end
    end

    test "body is required and limited in bytes", %{thread: thread, ag1: ag1} do
      assert "can't be blank" in errors(thread, ag1, [], %{kind: :note, body: ""}).body

      too_big = String.duplicate("é", div(Message.max_body_bytes(), 2) + 1)
      assert errors(thread, ag1, [], %{kind: :note, body: too_big}).body

      fits = String.duplicate("a", Message.max_body_bytes())
      refute Map.has_key?(errors(thread, ag1, [], %{kind: :note, body: fits}), :body)
    end

    test "number is unique per thread", %{thread: thread, ag1: ag1} do
      note_fixture(thread, ag1, %{number: 1})

      assert {:error, cs} =
               thread
               |> message_struct(ag1)
               |> Message.changeset(%{number: 1, kind: :note, body: "again"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(cs).thread_id
    end

    test "a response points to the request it answers", %{thread: thread, ag1: ag1, ag2: ag2} do
      request = request_fixture(thread, ag1, ag2)

      response =
        thread
        |> message_struct(ag2, reply_to_message_id: request.id)
        |> Message.changeset(%{number: unique_int(), kind: :response, body: "done"})
        |> Repo.insert!()

      assert Repo.preload(response, :reply_to_message).reply_to_message.id == request.id
    end
  end

  describe "context" do
    test "get_thread/2", %{session: session, thread: thread} do
      assert Threads.get_thread(session, 1).id == thread.id
      assert Threads.get_thread(session, 99) == nil
    end

    test "list_threads/2 newest activity first, filtered by status",
         %{session: session, ag1: ag1, thread: t1} do
      t2 =
        thread_fixture(ag1, %{
          number: 2,
          status: :answered,
          last_message_at: DateTime.add(DateTime.utc_now(), 60)
        })

      thread_fixture(agent_fixture(session_fixture()), %{number: 1})

      assert Enum.map(Threads.list_threads(session), & &1.id) == [t2.id, t1.id]
      assert Enum.map(Threads.list_threads(session, status: :answered), & &1.id) == [t2.id]
    end

    test "list_messages/1 in order", %{thread: thread, ag1: ag1, ag2: ag2} do
      m2 = note_fixture(thread, ag2, %{number: 2})
      m1 = request_fixture(thread, ag1, ag2, %{number: 1})

      assert Enum.map(Threads.list_messages(thread), & &1.id) == [m1.id, m2.id]
    end
  end
end
