defmodule C3.KnowledgeTest do
  use C3.DataCase

  import C3.Fixtures

  alias C3.Events.Event
  alias C3.Knowledge
  alias C3.Knowledge.Entry

  setup do
    session = session_fixture()
    ag1 = agent_fixture(session, %{number: 1})
    ag2 = agent_fixture(session, %{number: 2})
    %{session: session, ag1: ag1, ag2: ag2}
  end

  defp record(agent, attrs) do
    Knowledge.record(
      agent,
      Map.merge(%{"topic" => "auth", "kind" => "decision", "summary" => "JWT, 1 h"}, attrs)
    )
  end

  defp events(session) do
    Event
    |> where(session_id: ^session.id)
    |> order_by(:seq)
    |> Repo.all()
    |> Enum.map(&{&1.type, &1.payload})
  end

  describe "record/2" do
    test "numbers entries per session and emits knowledge.recorded", ctx do
      assert {:ok, k1} = record(ctx.ag1, %{"source" => "T3.4"})
      assert {:ok, k2} = record(ctx.ag2, %{"topic" => "db.schema", "kind" => "fact"})

      assert Knowledge.entry_ref(k1) == "K1"
      assert Knowledge.entry_ref(k2) == "K2"
      assert k1.status == :active
      assert k1.source == "T3.4"

      assert [
               {:knowledge_recorded,
                %{"entry" => "K1", "topic" => "auth", "author" => "AG1", "source" => "T3.4"}},
               {:knowledge_recorded, %{"entry" => "K2", "kind" => "fact", "author" => "AG2"}}
             ] = events(ctx.session)
    end

    test "numbering is independent per session", ctx do
      other = agent_fixture(session_fixture(), %{number: 1})
      assert {:ok, _} = record(ctx.ag1, %{})
      assert {:ok, entry} = record(other, %{})
      assert Knowledge.entry_ref(entry) == "K1"
    end

    test "supersedes marks the old entry superseded in the same transaction", ctx do
      {:ok, k1} = record(ctx.ag1, %{})
      assert {:ok, k2} = record(ctx.ag2, %{"summary" => "JWT, 15 min", "supersedes" => "K1"})

      assert Repo.get!(Entry, k1.id).status == :superseded
      assert k2.supersedes_id == k1.id

      assert [
               _,
               {:knowledge_superseded,
                %{"entry" => "K1", "superseded_by" => "K2", "by" => "AG2"}},
               {:knowledge_recorded, %{"entry" => "K2", "supersedes" => "K1"}}
             ] = events(ctx.session)
    end

    test "superseding an entry that is not active fails and writes nothing", ctx do
      {:ok, _} = record(ctx.ag1, %{})
      {:ok, _} = record(ctx.ag1, %{"supersedes" => "K1"})

      assert {:error, {:conflict, message, %{entry: "K1"}}} =
               record(ctx.ag2, %{"supersedes" => "K1"})

      assert message =~ "superseded"
      assert Repo.aggregate(Entry, :count) == 2
      assert Repo.get!(C3.Sessions.Session, ctx.session.id).next_knowledge_number == 3
    end

    test "superseding an unknown or malformed entry", ctx do
      assert {:error, :knowledge_not_found} = record(ctx.ag1, %{"supersedes" => "K9"})
      assert {:error, {:invalid, _, _}} = record(ctx.ag1, %{"supersedes" => "T1"})
    end

    test "an entry of another session cannot be superseded", ctx do
      other = agent_fixture(session_fixture(), %{number: 1})
      {:ok, _} = record(other, %{})
      assert {:error, :knowledge_not_found} = record(ctx.ag1, %{"supersedes" => "K1"})
    end

    test "validates topic, kind, summary and source", ctx do
      assert {:error, cs} = record(ctx.ag1, %{"topic" => "Auth Stuff"})
      assert errors_on(cs).topic
      assert {:error, cs} = record(ctx.ag1, %{"kind" => "opinion"})
      assert errors_on(cs).kind
      assert {:error, cs} = record(ctx.ag1, %{"summary" => ""})
      assert errors_on(cs).summary
      assert {:error, cs} = record(ctx.ag1, %{"source" => "somewhere"})
      assert errors_on(cs).source
      assert {:error, {:invalid, _, _}} = record(ctx.ag1, %{"summary" => 42})
    end

    test "a summary over the limit is too_large", ctx do
      too_big = String.duplicate("x", Entry.max_summary_bytes() + 1)
      assert {:error, {:too_large, _}} = record(ctx.ag1, %{"summary" => too_big})
    end
  end

  describe "recall/2" do
    setup ctx do
      {:ok, _} = record(ctx.ag1, %{"topic" => "auth", "summary" => "a"})
      {:ok, _} = record(ctx.ag1, %{"topic" => "auth.jwt", "kind" => "fact", "summary" => "b"})
      {:ok, _} = record(ctx.ag2, %{"topic" => "authz", "summary" => "c"})
      {:ok, _} = record(ctx.ag2, %{"topic" => "auth", "summary" => "d", "supersedes" => "K1"})
      {:ok, _} = record(ctx.ag1, %{"topic" => "deploy_x", "kind" => "todo", "summary" => "e"})
      :ok
    end

    defp refs({:ok, entries}), do: Enum.map(entries, &Knowledge.entry_ref/1)

    test "only active entries by default, in order", ctx do
      assert refs(Knowledge.recall(ctx.ag1)) == ~w(K2 K3 K4 K5)
    end

    test "topic matches itself and what is under it, not a longer word", ctx do
      assert refs(Knowledge.recall(ctx.ag1, %{"topic" => "auth"})) == ~w(K2 K4)

      assert refs(Knowledge.recall(ctx.ag1, %{"topic" => "auth", "status" => "all"})) ==
               ~w(K1 K2 K4)
    end

    test "_ in a topic is not a wildcard", ctx do
      assert refs(Knowledge.recall(ctx.ag1, %{"topic" => "deploy_x"})) == ~w(K5)
      assert refs(Knowledge.recall(ctx.ag1, %{"topic" => "deployax"})) == []
    end

    test "filters by kind and status, and limits to the latest", ctx do
      assert refs(Knowledge.recall(ctx.ag1, %{"kind" => "fact"})) == ~w(K2)
      assert refs(Knowledge.recall(ctx.ag1, %{"status" => "superseded"})) == ~w(K1)
      assert refs(Knowledge.recall(ctx.ag1, %{"limit" => "2"})) == ~w(K4 K5)
    end

    test "rejects bad parameters", ctx do
      assert {:error, {:invalid, _, _}} = Knowledge.recall(ctx.ag1, %{"kind" => "x"})
      assert {:error, {:invalid, _, _}} = Knowledge.recall(ctx.ag1, %{"status" => "x"})
      assert {:error, {:invalid, _, _}} = Knowledge.recall(ctx.ag1, %{"limit" => "0"})
      assert {:error, {:invalid, _, _}} = Knowledge.recall(ctx.ag1, %{"topic" => "a%"})
    end

    test "does not see other sessions", _ctx do
      other = agent_fixture(session_fixture(), %{number: 1})
      assert refs(Knowledge.recall(other)) == []
    end
  end

  describe "retract/3" do
    test "only the author retracts, once", ctx do
      {:ok, _} = record(ctx.ag1, %{})

      assert {:error, {:forbidden, _}} = Knowledge.retract(ctx.ag2, "K1")
      assert {:ok, entry} = Knowledge.retract(ctx.ag1, "K1", %{"reason" => "wrong"})
      assert entry.status == :retracted
      assert {:error, {:conflict, _, _}} = Knowledge.retract(ctx.ag1, "K1")

      assert {:knowledge_retracted, %{"entry" => "K1", "by" => "AG1", "reason" => "wrong"}} =
               List.last(events(ctx.session))
    end

    test "a retracted entry cannot be superseded", ctx do
      {:ok, _} = record(ctx.ag1, %{})
      {:ok, _} = Knowledge.retract(ctx.ag1, "K1")
      assert {:error, {:conflict, _, _}} = record(ctx.ag2, %{"supersedes" => "K1"})
    end

    test "unknown entry", ctx do
      assert {:error, :knowledge_not_found} = Knowledge.retract(ctx.ag1, "K7")
      assert {:error, {:invalid, _, _}} = Knowledge.retract(ctx.ag1, "nope")
    end
  end

  test "recall by source: a thread gives its entries and its messages'", ctx do
    {:ok, _} = record(ctx.ag1, %{"source" => "T3"})
    {:ok, _} = record(ctx.ag1, %{"topic" => "db", "source" => "T3.4"})
    {:ok, _} = record(ctx.ag1, %{"topic" => "ui", "source" => "T31"})
    {:ok, _} = record(ctx.ag1, %{"topic" => "ops"})

    refs = fn params ->
      {:ok, entries} = Knowledge.recall(ctx.ag1, params)
      Enum.map(entries, &Knowledge.entry_ref/1)
    end

    assert refs.(%{"source" => "T3"}) == ["K1", "K2"]
    assert refs.(%{"source" => "T3.4"}) == ["K2"]
    assert refs.(%{"source" => "T31"}) == ["K3"]
    assert {:error, {:invalid, _, %{source: _}}} = Knowledge.recall(ctx.ag1, %{"source" => "T%"})
  end

  test "purging the session deletes its entries", ctx do
    {:ok, _} = record(ctx.ag1, %{})
    {:ok, _} = record(ctx.ag2, %{"supersedes" => "K1"})
    {:ok, _} = C3.Sessions.close(ctx.ag1)
    assert {:ok, _} = C3.Sessions.Lifecycle.purge_session(ctx.session.id)
    assert Repo.aggregate(Entry, :count) == 0
  end
end
