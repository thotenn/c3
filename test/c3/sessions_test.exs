defmodule C3.SessionsTest do
  use C3.DataCase

  import C3.Fixtures

  alias C3.Sessions
  alias C3.Sessions.{Agent, IdempotencyKey, Session}

  describe "Session.changeset/2" do
    test "valid with code, secret hash and expiry; defaults applied" do
      session = session_fixture(%{label: "pairing"})

      assert session.status == :open

      assert {session.next_agent_number, session.next_thread_number, session.event_seq} ==
               {1, 1, 0}

      assert %DateTime{} = session.last_activity_at
    end

    test "requires code, secret_hash and expires_at" do
      errors = errors_on(Session.changeset(%Session{}, %{}))

      for field <- [:code, :secret_hash, :expires_at],
          do: assert("can't be blank" in errors[field])
    end

    test "rejects unknown status and close reason" do
      cs = Session.changeset(%Session{}, %{status: "paused", close_reason: "boredom"})
      assert "is invalid" in errors_on(cs).status
      assert "is invalid" in errors_on(cs).close_reason
    end

    test "limits the label to 200 characters" do
      cs = Session.changeset(%Session{}, %{label: String.duplicate("a", 201)})
      assert "should be at most 200 character(s)" in errors_on(cs).label
    end

    test "closed_at is set exactly when the session is closed" do
      now = DateTime.utc_now()
      assert errors_on(Session.changeset(%Session{}, %{status: :closed})).closed_at
      assert errors_on(Session.changeset(%Session{}, %{closed_at: now})).closed_at

      refute Map.has_key?(
               errors_on(Session.changeset(%Session{}, %{status: :closed, closed_at: now})),
               :closed_at
             )
    end

    test "closed_by is an agent name, system or admin" do
      for ok <- ["AG2", "system", "admin"] do
        refute Map.has_key?(
                 errors_on(Session.changeset(%Session{}, %{closed_by: ok})),
                 :closed_by
               )
      end

      for bad <- ["AG0", "ag2", "root"] do
        assert errors_on(Session.changeset(%Session{}, %{closed_by: bad})).closed_by
      end
    end

    test "code is unique" do
      session_fixture(%{code: "C3-AAAA-BBBB"})

      assert {:error, cs} =
               %Session{}
               |> Session.changeset(%{
                 code: "C3-AAAA-BBBB",
                 secret_hash: "h",
                 expires_at: DateTime.utc_now()
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(cs).code
    end
  end

  describe "Agent.changeset/2" do
    setup do
      %{session: session_fixture()}
    end

    test "valid agent defaults to active", %{session: session} do
      agent = agent_fixture(session, %{number: 1, label: "backend-win"})
      assert agent.name == "AG1"
      assert agent.status == :active
      assert agent.alerts_seen_seq == 0
      assert %DateTime{} = agent.last_seen_at
    end

    test "name must match the number" do
      cs = Agent.changeset(%Agent{}, %{number: 2, name: "AG3", token_hash: "t", joined_ip: "ip"})
      assert "must be AG followed by the agent number" in errors_on(cs).name
    end

    test "label format" do
      for ok <- ["backend", "b", "backend-win", "a1-" <> String.duplicate("x", 37)] do
        refute Map.has_key?(errors_on(Agent.changeset(%Agent{}, %{label: ok})), :label)
      end

      for bad <- ["Backend", "-backend", "back end", "a" <> String.duplicate("x", 40)] do
        assert errors_on(Agent.changeset(%Agent{}, %{label: bad})).label
      end
    end

    test "left_at is set exactly when the agent is no longer active" do
      assert errors_on(Agent.changeset(%Agent{}, %{status: :left})).left_at

      assert errors_on(Agent.changeset(%Agent{}, %{left_at: DateTime.utc_now()})).left_at

      refute Map.has_key?(
               errors_on(
                 Agent.changeset(%Agent{}, %{status: :revoked, left_at: DateTime.utc_now()})
               ),
               :left_at
             )
    end

    test "number, name and token_hash are unique", %{session: session} do
      agent = agent_fixture(session, %{number: 1})

      dup = fn attrs ->
        %Agent{session_id: session.id}
        |> Agent.changeset(
          Enum.into(attrs, %{number: 2, name: "AG2", token_hash: "other", joined_ip: "ip"})
        )
        |> Repo.insert()
      end

      assert {:error, cs} = dup.(%{number: 1, name: "AG1"})
      assert "has already been taken" in errors_on(cs).session_id
      assert {:error, cs} = dup.(%{token_hash: agent.token_hash})
      assert "has already been taken" in errors_on(cs).token_hash
    end

    test "the same label may repeat within a session", %{session: session} do
      agent_fixture(session, %{label: "backend"})
      assert %Agent{} = agent_fixture(session, %{label: "backend"})
    end

    test "the same number may repeat across sessions", %{session: session} do
      agent_fixture(session, %{number: 1})
      assert %Agent{name: "AG1"} = agent_fixture(session_fixture(), %{number: 1})
    end

    test "an unknown session is rejected by the foreign key" do
      assert_raise Ecto.ConstraintError, ~r/foreign_key/, fn ->
        agent_fixture(%Session{id: -1})
      end
    end
  end

  describe "IdempotencyKey.changeset/2" do
    setup do
      %{agent: agent_fixture(session_fixture())}
    end

    test "requires every column and limits the key", %{agent: agent} do
      cs = IdempotencyKey.changeset(%IdempotencyKey{}, %{})

      assert errors_on(cs) |> Map.keys() |> Enum.sort() ==
               [:key, :request_hash, :response_body, :response_status]

      cs = IdempotencyKey.changeset(%IdempotencyKey{}, %{key: String.duplicate("k", 101)})
      assert "should be at most 100 character(s)" in errors_on(cs).key

      cs = IdempotencyKey.changeset(%IdempotencyKey{}, %{response_status: 99})
      assert errors_on(cs).response_status

      assert %IdempotencyKey{response_body: %{"ok" => true}} = idempotency_key_fixture(agent)
    end

    test "a key is unique per agent", %{agent: agent} do
      idempotency_key_fixture(agent, %{key: "k1"})

      assert {:error, cs} =
               %IdempotencyKey{agent_id: agent.id}
               |> IdempotencyKey.changeset(%{
                 key: "k1",
                 request_hash: "x",
                 response_status: 200,
                 response_body: %{}
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(cs).agent_id
      assert idempotency_key_fixture(agent_fixture(session_fixture()), %{key: "k1"})
    end
  end

  describe "context" do
    test "get_session_by_code/1" do
      session = session_fixture()
      assert Sessions.get_session_by_code(session.code).id == session.id
      assert Sessions.get_session_by_code("C3-NOPE") == nil
    end

    test "get_agent_by_token_hash/1 preloads the session" do
      session = session_fixture()
      agent = agent_fixture(session)

      assert %Agent{session: %Session{id: id}} =
               Sessions.get_agent_by_token_hash(agent.token_hash)

      assert id == session.id
      assert Sessions.get_agent_by_token_hash("nope") == nil
    end

    test "list_agents/1 in join order, only that session" do
      session = session_fixture()
      a2 = agent_fixture(session, %{number: 2})
      a1 = agent_fixture(session, %{number: 1})
      agent_fixture(session_fixture(), %{number: 1})

      assert Enum.map(Sessions.list_agents(session), & &1.id) == [a1.id, a2.id]
    end

    test "get_idempotency_key/2" do
      agent = agent_fixture(session_fixture())
      key = idempotency_key_fixture(agent, %{key: "k1"})

      assert Sessions.get_idempotency_key(agent, "k1").id == key.id
      assert Sessions.get_idempotency_key(agent, "k2") == nil
    end
  end
end
