defmodule C3.DbConstraintsTest do
  @moduledoc """
  The database enforces `schema.md` on its own: rows are inserted raw, bypassing the
  changesets, so every CHECK, foreign key and ON DELETE rule is exercised by SQLite.
  """
  use C3.DataCase, async: true

  import C3.Fixtures

  alias C3.Events.Event
  alias C3.Security.JoinFailure
  alias C3.Sessions.{Agent, IdempotencyKey, Session}
  alias C3.Threads.{Message, Thread}

  setup do
    session = session_fixture()
    ag1 = agent_fixture(session, %{number: 1})
    ag2 = agent_fixture(session, %{number: 2})
    thread = thread_fixture(ag1, %{number: 1})
    %{session: session, ag1: ag1, ag2: ag2, thread: thread}
  end

  defp now, do: DateTime.utc_now()

  defp insert(table, row), do: Repo.insert_all(table, [row])

  defp assert_check(table, row, name) do
    assert_sqlite_error("CHECK constraint failed: #{name}", fn -> insert(table, row) end)
  end

  defp assert_fk(table, row) do
    assert_sqlite_error("FOREIGN KEY constraint failed", fn -> insert(table, row) end)
  end

  defp assert_sqlite_error(message, fun) do
    error = assert_raise Exqlite.Error, fun
    assert error.message == message
  end

  describe "sessions" do
    defp session_row(overrides) do
      Map.merge(
        %{
          code: "C3-RAW-#{unique_int()}",
          secret_hash: "h",
          last_activity_at: now(),
          expires_at: now(),
          inserted_at: now(),
          updated_at: now()
        },
        overrides
      )
    end

    test "a valid raw row passes and takes the defaults" do
      assert {1, _} = insert("sessions", session_row(%{code: "C3-RAW"}))

      assert %Session{status: :open, next_agent_number: 1, event_seq: 0} =
               Repo.get_by!(Session, code: "C3-RAW")
    end

    test "CHECKs" do
      assert_check("sessions", session_row(%{status: "paused"}), "sessions_status_check")
      assert_check("sessions", session_row(%{status: "closed"}), "sessions_closed_at_check")
      assert_check("sessions", session_row(%{closed_at: now()}), "sessions_closed_at_check")

      assert_check(
        "sessions",
        session_row(%{close_reason: "boredom"}),
        "sessions_close_reason_check"
      )

      assert {1, _} =
               insert(
                 "sessions",
                 session_row(%{status: "closed", closed_at: now(), close_reason: "idle"})
               )
    end
  end

  describe "agents" do
    defp agent_row(session, overrides) do
      n = unique_int()

      Map.merge(
        %{
          session_id: session.id,
          number: n,
          name: "AG#{n}",
          token_hash: "raw-#{n}",
          joined_ip: "ip",
          last_seen_at: now(),
          inserted_at: now(),
          updated_at: now()
        },
        overrides
      )
    end

    test "CHECK and foreign key", %{session: session} do
      assert_check("agents", agent_row(session, %{status: "gone"}), "agents_status_check")

      assert_fk("agents", agent_row(%Session{id: -1}, %{}))
    end
  end

  describe "threads" do
    defp thread_row(ag, overrides) do
      Map.merge(
        %{
          session_id: ag.session_id,
          number: unique_int(),
          title: "t",
          opened_by_agent_id: ag.id,
          last_message_at: now(),
          inserted_at: now(),
          updated_at: now()
        },
        overrides
      )
    end

    test "CHECKs and foreign keys", %{ag1: ag1} do
      assert_check("threads", thread_row(ag1, %{status: "stuck"}), "threads_status_check")
      assert_check("threads", thread_row(ag1, %{status: "finished"}), "threads_finished_at_check")
      assert_check("threads", thread_row(ag1, %{finished_at: now()}), "threads_finished_at_check")

      assert_fk("threads", thread_row(%Agent{id: -1, session_id: ag1.session_id}, %{}))
    end
  end

  describe "messages" do
    defp message_row(thread, author, overrides) do
      Map.merge(
        %{
          thread_id: thread.id,
          session_id: thread.session_id,
          number: unique_int(),
          kind: "note",
          author_agent_id: author && author.id,
          body: "b",
          inserted_at: now()
        },
        overrides
      )
    end

    defp request(to_target, extra \\ %{}),
      do: Map.merge(%{kind: "request", to_target: to_target, request_state: "open"}, extra)

    test "valid requests to an agent, a label and any", %{thread: t, ag1: ag1, ag2: ag2} do
      assert {1, _} =
               insert("messages", message_row(t, ag1, request("agent", %{to_agent_id: ag2.id})))

      assert {1, _} = insert("messages", message_row(t, ag1, request("label", %{to_label: "be"})))
      assert {1, _} = insert("messages", message_row(t, ag1, request("any")))
      assert {1, _} = insert("messages", message_row(t, nil, %{kind: "system"}))
    end

    test "kind and author", %{thread: t, ag1: ag1} do
      assert_check("messages", message_row(t, ag1, %{kind: "chat"}), "messages_kind_check")
      assert_check("messages", message_row(t, nil, %{}), "messages_author_check")
      assert_check("messages", message_row(t, ag1, %{kind: "system"}), "messages_author_check")
    end

    test "to_target and request_state exist exactly for requests", %{thread: t, ag1: ag1} do
      assert_check(
        "messages",
        message_row(t, ag1, request("everyone")),
        "messages_to_target_check"
      )

      assert_check(
        "messages",
        message_row(t, ag1, %{kind: "request", request_state: "open"}),
        "messages_to_target_check"
      )

      assert_check(
        "messages",
        message_row(t, ag1, %{to_target: "any"}),
        "messages_to_target_check"
      )

      assert_check(
        "messages",
        message_row(t, ag1, %{kind: "request", to_target: "any"}),
        "messages_request_state_check"
      )

      assert_check(
        "messages",
        message_row(t, ag1, %{request_state: "open"}),
        "messages_request_state_check"
      )

      assert_check(
        "messages",
        message_row(t, ag1, request("any", %{request_state: "lost"})),
        "messages_request_state_check"
      )
    end

    test "the target column matches to_target", %{thread: t, ag1: ag1, ag2: ag2} do
      assert_check("messages", message_row(t, ag1, request("agent")), "messages_to_agent_check")

      assert_check(
        "messages",
        message_row(t, ag1, request("any", %{to_agent_id: ag2.id})),
        "messages_to_agent_check"
      )

      assert_check("messages", message_row(t, ag1, request("label")), "messages_to_label_check")

      assert_check(
        "messages",
        message_row(t, ag1, request("any", %{to_label: "be"})),
        "messages_to_label_check"
      )
    end

    test "claimed_by follows request_state", %{thread: t, ag1: ag1, ag2: ag2} do
      by = %{claimed_by_agent_id: ag2.id}

      assert_check(
        "messages",
        message_row(t, ag1, request("any", %{request_state: "claimed"})),
        "messages_claimed_by_check"
      )

      for state <- ["open", "cancelled"] do
        assert_check(
          "messages",
          message_row(t, ag1, request("any", Map.put(by, :request_state, state))),
          "messages_claimed_by_check"
        )
      end

      assert_check("messages", message_row(t, ag1, by), "messages_claimed_by_check")

      for extra <- [
            Map.put(by, :request_state, "claimed"),
            Map.put(by, :request_state, "done"),
            %{request_state: "done"}
          ] do
        assert {1, _} = insert("messages", message_row(t, ag1, request("any", extra)))
      end
    end

    test "foreign keys", %{thread: t, ag1: ag1} do
      for bad <- [%{to_agent_id: -1}, %{reply_to_message_id: -1}, %{thread_id: -1}] do
        assert_fk(
          "messages",
          message_row(t, ag1, Map.merge(request("agent", %{to_agent_id: ag1.id}), bad))
        )
      end
    end
  end

  test "events, join_failures and ip_bans enums", %{session: session} do
    row = %{session_id: session.id, seq: 1, type: "agent.danced", inserted_at: now()}
    assert_check("events", row, "events_type_check")
    assert {1, _} = insert("events", %{row | type: "session.closing_soon"})
    assert Repo.get_by!(Event, session_id: session.id).payload == %{}

    jf = %{ip: "ip", reason: "bad_luck", attempted_code: "C3-X", inserted_at: now()}
    assert_check("join_failures", jf, "join_failures_reason_check")
    assert {1, _} = insert("join_failures", %{jf | reason: "joins_locked"})

    ban = %{ip: "ip", reason: "session_closed", banned_until: now(), inserted_at: now()}
    assert_check("ip_bans", ban, "ip_bans_reason_check")
    assert {1, _} = insert("ip_bans", %{ban | reason: "admin"})
  end

  describe "ON DELETE" do
    test "deleting a session cascades and keeps join failures as audit",
         %{session: session, ag1: ag1, ag2: ag2, thread: thread} do
      request = request_fixture(thread, ag1, ag2)
      event_fixture(session, %{seq: 1, thread_id: thread.id, message_id: request.id})
      idempotency_key_fixture(ag1)
      failure = join_failure_fixture(session)
      ban = ip_ban_fixture(%{session_code: session.code})

      other_agent = agent_fixture(session_fixture())

      Repo.delete!(session)

      for schema <- [Agent, Thread, Message, Event] do
        assert Repo.aggregate(where(schema, session_id: ^session.id), :count) == 0,
               "#{inspect(schema)} rows survived the session"
      end

      assert Repo.aggregate(where(IdempotencyKey, [k], k.agent_id in ^[ag1.id, ag2.id]), :count) ==
               0

      assert %JoinFailure{session_id: nil} = Repo.reload!(failure)
      assert Repo.reload!(ban).session_code == session.code
      assert Repo.reload!(other_agent)
    end
  end
end
