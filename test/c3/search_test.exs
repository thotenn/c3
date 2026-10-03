defmodule C3.SearchTest do
  use C3.DataCase

  import C3.Fixtures

  alias C3.{Search, Threads}

  setup do
    session = session_fixture()
    ag1 = agent_fixture(session, %{number: 1})
    ag2 = agent_fixture(session, %{number: 2})

    {:ok, t1} =
      Threads.open_thread(ag1, %{
        "title" => "Deploy staging",
        "body" => "Run the MIGRATION on staging and paste the output",
        "to" => "AG2"
      })

    {:ok, _} =
      Threads.post_message(ag2, t1, %{
        "kind" => "response",
        "body" => "Done: 3 migrations, 100% ok"
      })

    {:ok, t2} = Threads.open_thread(ag2, %{"title" => "Docs", "body" => "Update api_md please"})

    %{session: session, ag1: ag1, ag2: ag2, t1: t1, t2: t2}
  end

  defp found(agent, params) do
    {:ok, messages, _terms} = Search.messages(agent, params)
    Enum.map(messages, &Threads.message_ref(&1.thread, &1))
  end

  test "every term, in the body or the title, ignoring case; newest first", ctx do
    assert found(ctx.ag1, %{"q" => "migration"}) == ["T1.2", "T1.1"]
    assert found(ctx.ag1, %{"q" => "migration paste"}) == ["T1.1"]
    assert found(ctx.ag1, %{"q" => "staging done"}) == ["T1.2"], "staging is in the title"
    assert found(ctx.ag1, %{"q" => "nothing here"}) == []
  end

  test "%, _ and \\ are literal", ctx do
    assert found(ctx.ag1, %{"q" => "100%"}) == ["T1.2"]
    assert found(ctx.ag1, %{"q" => "0%"}) == ["T1.2"]
    assert found(ctx.ag1, %{"q" => "api_md"}) == ["T2.1"]
    assert found(ctx.ag1, %{"q" => "api%md"}) == []
    assert found(ctx.ag1, %{"q" => "a_i"}) == []
  end

  test "filters by thread, kind and limit; never leaves the session", ctx do
    assert found(ctx.ag1, %{"q" => "the", "thread" => "T1"}) == ["T1.1"]
    assert found(ctx.ag1, %{"q" => "migration", "kind" => "response"}) == ["T1.2"]
    assert found(ctx.ag1, %{"q" => "migration", "limit" => "1"}) == ["T1.2"]

    other = agent_fixture(session_fixture(), %{number: 1})
    assert found(other, %{"q" => "migration"}) == []
  end

  test "checks its arguments", ctx do
    for {params, field} <- [
          {%{}, :q},
          {%{"q" => "  "}, :q},
          {%{"q" => "a deploy"}, :q},
          {%{"q" => Enum.map_join(1..9, " ", &"w#{&1}")}, :q},
          {%{"q" => String.duplicate("x", 201)}, :q},
          {%{"q" => "deploy", "thread" => "K1"}, :thread},
          {%{"q" => "deploy", "kind" => "system"}, :kind},
          {%{"q" => "deploy", "limit" => 101}, :limit}
        ] do
      assert {:error, {:invalid, _, %{^field => _}}} = Search.messages(ctx.ag1, params),
             "#{inspect(params)} should fail on #{field}"
    end
  end

  test "a snippet around the first term, cut with …" do
    body =
      String.duplicate("lorem ipsum ", 30) <>
        "the NEEDLE is here " <> String.duplicate("dolor ", 30)

    snippet = Search.snippet(body, ["needle"])

    assert snippet =~ ~r/^….*NEEDLE.*…$/u
    assert String.length(snippet) <= 162
    assert Search.snippet("short body", ["title-only"]) == "short body"
  end
end
