defmodule C3Web.V1.KnowledgeControllerTest do
  use C3Web.ConnCase

  alias C3.Knowledge.Entry

  defp fresh_conn, do: with_ip(build_conn(), unique_ip())

  defp authed(token), do: put_req_header(fresh_conn(), "authorization", "Bearer " <> token)

  # A session with AG1 and AG2: %{code, t1, t2}.
  defp session! do
    created = fresh_conn() |> post(~p"/v1/sessions", %{}) |> json_response(201)
    %{"session_code" => code, "secret" => secret, "agent" => %{"token" => t1}} = created

    %{"agent" => %{"token" => t2}} =
      fresh_conn()
      |> post(~p"/v1/sessions/#{code}/join", %{"secret" => secret})
      |> json_response(201)

    %{code: code, t1: t1, t2: t2}
  end

  defp record(s, token, attrs) do
    authed(token)
    |> post(
      ~p"/v1/sessions/#{s.code}/knowledge",
      Map.merge(%{"topic" => "auth", "kind" => "decision", "summary" => "JWT, 1 h"}, attrs)
    )
  end

  setup do: %{s: session!()}

  test "record, supersede, recall and retract", %{s: s} do
    assert %{
             "id" => "K1",
             "topic" => "auth",
             "kind" => "decision",
             "summary" => "JWT, 1 h",
             "status" => "active",
             "author" => "AG1",
             "source" => "T2.3",
             "supersedes" => nil
           } = record(s, s.t1, %{"source" => "T2.3"}) |> json_response(201)

    assert %{"id" => "K2", "supersedes" => "K1", "author" => "AG2"} =
             record(s, s.t2, %{"summary" => "JWT, 15 min", "supersedes" => "K1"})
             |> json_response(201)

    assert %{"entries" => [%{"id" => "K2", "summary" => "JWT, 15 min"}]} =
             authed(s.t1) |> get(~p"/v1/sessions/#{s.code}/knowledge") |> json_response(200)

    assert %{"entries" => [%{"id" => "K1", "status" => "superseded"}, %{"id" => "K2"}]} =
             authed(s.t1)
             |> get(~p"/v1/sessions/#{s.code}/knowledge?topic=auth&status=all")
             |> json_response(200)

    assert %{"error" => %{"code" => "forbidden"}} =
             authed(s.t1) |> post(~p"/v1/knowledge/K2/retract", %{}) |> json_response(403)

    assert %{"id" => "K2", "status" => "retracted"} =
             authed(s.t2)
             |> post(~p"/v1/knowledge/K2/retract", %{"reason" => "wrong"})
             |> json_response(200)

    assert %{"entries" => []} =
             authed(s.t1) |> get(~p"/v1/sessions/#{s.code}/knowledge") |> json_response(200)
  end

  test "errors", %{s: s} do
    assert %{"error" => %{"code" => "invalid_request", "details" => %{"kind" => _}}} =
             record(s, s.t1, %{"kind" => "opinion"}) |> json_response(422)

    too_big = String.duplicate("x", Entry.max_summary_bytes() + 1)

    assert %{"error" => %{"code" => "too_large"}} =
             record(s, s.t1, %{"summary" => too_big}) |> json_response(413)

    assert %{"error" => %{"code" => "not_found"}} =
             record(s, s.t1, %{"supersedes" => "K9"}) |> json_response(404)

    assert %{"error" => %{"code" => "not_found"}} =
             authed(s.t1) |> post(~p"/v1/knowledge/K9/retract", %{}) |> json_response(404)

    record(s, s.t1, %{}) |> json_response(201)
    record(s, s.t1, %{"supersedes" => "K1"}) |> json_response(201)

    assert %{"error" => %{"code" => "conflict", "details" => %{"entry" => "K1"}}} =
             record(s, s.t2, %{"supersedes" => "K1"}) |> json_response(409)

    assert %{"error" => %{"code" => "invalid_request"}} =
             authed(s.t1)
             |> get(~p"/v1/sessions/#{s.code}/knowledge?status=bogus")
             |> json_response(422)
  end

  test "an idempotency key replays a record instead of recording twice", %{s: s} do
    conn = fn -> authed(s.t1) |> put_req_header("idempotency-key", "k-1") end
    body = %{"topic" => "db", "kind" => "fact", "summary" => "SQLite"}

    first = conn.() |> post(~p"/v1/sessions/#{s.code}/knowledge", body) |> json_response(201)
    again = conn.() |> post(~p"/v1/sessions/#{s.code}/knowledge", body) |> json_response(201)

    assert first == again
    assert C3.Repo.aggregate(Entry, :count) == 1
  end

  test "a closed session rejects a record", %{s: s} do
    authed(s.t1) |> post(~p"/v1/sessions/#{s.code}/close", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "session_closed"}} =
             record(s, s.t1, %{}) |> json_response(410)
  end

  describe "finish with record" do
    setup %{s: s} do
      authed(s.t1)
      |> post(~p"/v1/sessions/#{s.code}/threads", %{
        "title" => "Auth?",
        "body" => "How long do tokens last?",
        "to" => "AG2"
      })
      |> json_response(201)

      authed(s.t2)
      |> post(~p"/v1/threads/T1/messages", %{"kind" => "response", "body" => "15 min"})
      |> json_response(201)

      :ok
    end

    test "records the entry with the thread as its source", %{s: s} do
      assert %{
               "finished" => true,
               "recorded" => %{"id" => "K1", "source" => "T1", "author" => "AG1"}
             } =
               authed(s.t1)
               |> post(~p"/v1/threads/T1/finish", %{
                 "record" => %{"topic" => "auth", "kind" => "decision", "summary" => "15 min"}
               })
               |> json_response(200)

      # Finishing again changes nothing and records nothing.
      refute Map.has_key?(
               authed(s.t1)
               |> post(~p"/v1/threads/T1/finish", %{
                 "record" => %{"topic" => "auth", "kind" => "decision", "summary" => "15 min"}
               })
               |> json_response(200),
               "recorded"
             )

      assert C3.Repo.aggregate(Entry, :count) == 1
    end

    test "a bad record leaves the thread unfinished", %{s: s} do
      assert %{"error" => %{"code" => "invalid_request"}} =
               authed(s.t1)
               |> post(~p"/v1/threads/T1/finish", %{
                 "record" => %{"topic" => "Bad Topic", "kind" => "decision", "summary" => "x"}
               })
               |> json_response(422)

      assert %{"status" => "answered"} =
               authed(s.t1) |> get(~p"/v1/threads/T1") |> json_response(200)

      assert %{"error" => %{"code" => "invalid_request"}} =
               authed(s.t1)
               |> post(~p"/v1/threads/T1/finish", %{"record" => "not an object"})
               |> json_response(422)
    end

    test "without record the answer is unchanged", %{s: s} do
      body = authed(s.t1) |> post(~p"/v1/threads/T1/finish", %{}) |> json_response(200)
      assert Map.keys(body) |> Enum.sort() == ~w(cancelled finished thread)
    end
  end
end
