defmodule C3Web.V1.ThreadControllerTest do
  use C3Web.ConnCase

  import Ecto.Query

  alias C3.{Idempotency, Repo, Sessions}
  alias C3.Sessions.{Agent, IdempotencyKey}
  alias C3.Threads.{Message, Thread}

  defp fresh_conn, do: with_ip(build_conn(), unique_ip())

  defp authed(token), do: put_req_header(fresh_conn(), "authorization", "Bearer " <> token)

  # A session with AG1 (no label) and AG2 (label backend): %{code, secret, t1, t2}.
  defp session! do
    created = fresh_conn() |> post(~p"/v1/sessions", %{}) |> json_response(201)
    %{"session_code" => code, "secret" => secret, "agent" => %{"token" => t1}} = created

    %{"agent" => %{"token" => t2}} =
      fresh_conn()
      |> post(~p"/v1/sessions/#{code}/join", %{"secret" => secret, "agent_label" => "backend"})
      |> json_response(201)

    %{code: code, secret: secret, t1: t1, t2: t2}
  end

  defp open(s, body \\ %{"title" => "Deploy?", "body" => "Can you deploy?", "to" => "AG2"}) do
    authed(s.t1) |> post(~p"/v1/sessions/#{s.code}/threads", body)
  end

  setup do: %{s: session!()}

  describe "threads" do
    test "open, read, claim, answer, finish and reopen", %{s: s} do
      assert %{
               "id" => "T1",
               "status" => "pending",
               "opened_by" => "AG1",
               "awaiting" => ["AG2"],
               "processing_by" => [],
               "messages" => [
                 %{
                   "id" => "T1.1",
                   "kind" => "request",
                   "author" => "AG1",
                   "to" => "AG2",
                   "state" => "open",
                   "claimed_by" => nil
                 }
               ]
             } = open(s) |> json_response(201)

      assert %{"claimed" => ["T1.1"], "thread" => %{"status" => "processing"}} =
               authed(s.t2) |> post(~p"/v1/threads/T1/claim", %{}) |> json_response(200)

      assert %{
               "resolved" => ["T1.1"],
               "messages" => [%{"id" => "T1.2", "kind" => "response", "reply_to" => "T1.1"}],
               "thread" => %{"status" => "answered"}
             } =
               authed(s.t2)
               |> post(~p"/v1/threads/t1/messages", %{"kind" => "response", "body" => "Done"})
               |> json_response(201)

      assert %{"messages" => [%{"id" => "T1.2"}]} =
               authed(s.t1) |> get(~p"/v1/threads/T1?since=T1.1") |> json_response(200)

      assert %{"finished" => true, "cancelled" => [], "thread" => %{"status" => "finished"}} =
               authed(s.t1) |> post(~p"/v1/threads/T1/finish", %{}) |> json_response(200)

      assert %{"reopened" => true, "thread" => %{"status" => "answered"}} =
               authed(s.t1) |> post(~p"/v1/threads/T1/reopen", %{}) |> json_response(200)
    end

    test "list, filtered by status and awaiting=me", %{s: s} do
      open(s)

      authed(s.t2)
      |> post(~p"/v1/sessions/#{s.code}/threads", %{
        "title" => "Other",
        "body" => "b",
        "to" => "AG1"
      })
      |> json_response(201)

      open(s, %{"title" => "Mine", "body" => "b", "to" => "label:backend"})

      ids = fn conn ->
        conn |> json_response(200) |> Map.fetch!("threads") |> Enum.map(& &1["id"])
      end

      assert authed(s.t1) |> get(~p"/v1/sessions/#{s.code}/threads") |> ids.() ==
               ["T3", "T2", "T1"]

      assert authed(s.t2) |> get(~p"/v1/sessions/#{s.code}/threads?awaiting=me") |> ids.() ==
               ["T3", "T1"]

      assert authed(s.t1) |> get(~p"/v1/sessions/#{s.code}/threads?status=answered") |> ids.() ==
               []

      for query <- ["status=done", "awaiting=AG2"] do
        assert %{"error" => %{"code" => "invalid_request"}} =
                 authed(s.t1)
                 |> get("/v1/sessions/#{s.code}/threads?#{query}")
                 |> json_response(422)
      end
    end

    test "to a list: one request per target in the same call", %{s: s} do
      %{"agent" => %{"token" => _}} =
        fresh_conn()
        |> post(~p"/v1/sessions/#{s.code}/join", %{"secret" => s.secret})
        |> json_response(201)

      body = %{"title" => "Both", "body" => "b", "to" => ["AG2", "AG3"]}

      assert %{"awaiting" => ["AG2", "AG3"], "messages" => [%{"to" => "AG2"}, %{"to" => "AG3"}]} =
               open(s, body) |> json_response(201)
    end

    test "an unknown or departed target is a 422", %{s: s} do
      assert %{"error" => %{"code" => "invalid_request", "details" => %{"to" => _}}} =
               open(s, %{"title" => "t", "body" => "b", "to" => "AG7"}) |> json_response(422)

      authed(s.t2) |> post(~p"/v1/sessions/#{s.code}/leave", %{}) |> json_response(200)

      assert %{"error" => %{"message" => "AG2 is no longer in the session"}} =
               open(s) |> json_response(422)
    end

    test "conflicts and permissions", %{s: s} do
      open(s, %{"title" => "t", "body" => "b", "to" => "any"})

      assert %{"error" => %{"code" => "forbidden"}} =
               authed(s.t2) |> post(~p"/v1/threads/T1/finish", %{}) |> json_response(403)

      assert %{"error" => %{"code" => "conflict", "details" => %{"pending" => ["T1.1"]}}} =
               authed(s.t1) |> post(~p"/v1/threads/T1/finish", %{}) |> json_response(409)

      %{"agent" => %{"token" => t3}} =
        fresh_conn()
        |> post(~p"/v1/sessions/#{s.code}/join", %{"secret" => s.secret})
        |> json_response(201)

      authed(s.t2) |> post(~p"/v1/threads/T1/claim", %{}) |> json_response(200)

      # AG1 wrote the any request, so it is not addressed to them.
      assert %{"error" => %{"code" => "forbidden"}} =
               authed(s.t1)
               |> post(~p"/v1/threads/T1/claim", %{"request_id" => "T1.1"})
               |> json_response(403)

      assert %{
               "error" => %{
                 "code" => "conflict",
                 "details" => %{"claimed_by" => %{"T1.1" => "AG2"}}
               }
             } =
               authed(t3) |> post(~p"/v1/threads/T1/claim", %{}) |> json_response(409)

      assert %{"cancelled" => ["T1.1"], "thread" => %{"status" => "finished"}} =
               authed(s.t1)
               |> post(~p"/v1/threads/T1/finish", %{"force" => true})
               |> json_response(200)
    end

    test "an unknown thread, or one of another session, is a 404", %{s: s} do
      open(s)
      other = session!()

      for path <- ["/v1/threads/T9", "/v1/threads/1", "/v1/threads/nope"] do
        assert %{"error" => %{"code" => "not_found"}} =
                 authed(s.t1) |> get(path) |> json_response(404)
      end

      assert %{"error" => %{"code" => "not_found"}} =
               authed(other.t1) |> get(~p"/v1/threads/T1") |> json_response(404)
    end

    test "bodies over the limit are 413 too_large", %{s: s} do
      big = String.duplicate("x", Message.max_body_bytes() + 1)

      assert %{"error" => %{"code" => "too_large"}} =
               open(s, %{"title" => "t", "body" => big, "to" => "AG2"}) |> json_response(413)

      assert_error_sent 413, fn ->
        authed(s.t1)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/sessions/#{s.code}/threads", String.duplicate(" ", 1_100_000))
      end
    end
  end

  describe "authentication without :code" do
    test "no token is a 401 on /threads and /inbox" do
      for path <- ["/v1/threads/T1", "/v1/inbox"] do
        assert %{"error" => %{"code" => "unauthorized"}} =
                 fresh_conn() |> get(path) |> json_response(401)
      end
    end

    test "a token of another session is still a 403 on its routes", %{s: s} do
      other = session!()

      assert %{"error" => %{"code" => "forbidden"}} =
               authed(other.t1) |> get(~p"/v1/sessions/#{s.code}/threads") |> json_response(403)
    end

    test "a closed session is a 410 on /threads and /inbox", %{s: s} do
      open(s)
      authed(s.t1) |> post(~p"/v1/sessions/#{s.code}/close", %{}) |> json_response(200)

      for {method, path} <- [
            get: "/v1/threads/T1",
            post: "/v1/threads/T1/claim",
            get: "/v1/inbox"
          ] do
        assert %{"error" => %{"code" => "session_closed"}} =
                 authed(s.t2) |> dispatch(@endpoint, method, path, %{}) |> json_response(410)
      end
    end

    test "any authenticated request refreshes last_seen_at, throttled", %{s: s} do
      agent = Sessions.get_agent_by_token(s.t2)
      old = DateTime.add(DateTime.utc_now(), -3600)
      Repo.update_all(where(Agent, id: ^agent.id), set: [last_seen_at: old])

      authed(s.t2) |> get(~p"/v1/inbox") |> json_response(200)
      seen = Repo.reload!(agent).last_seen_at
      assert DateTime.compare(seen, old) == :gt

      authed(s.t2) |> get(~p"/v1/inbox") |> json_response(200)
      assert Repo.reload!(agent).last_seen_at == seen
    end
  end

  describe "GET /v1/inbox" do
    test "requests grouped by thread, then alerts once", %{s: s} do
      assert %{"you" => "AG2", "empty" => true, "threads" => [], "alerts" => []} =
               authed(s.t2) |> get(~p"/v1/inbox") |> json_response(200)

      open(s)
      fresh_conn() |> post(~p"/v1/sessions/#{s.code}/join", %{"secret" => "000000x"})

      assert %{
               "empty" => false,
               "threads" => [
                 %{
                   "id" => "T1",
                   "status" => "pending",
                   "requests" => [
                     %{"id" => "T1.1", "from" => "AG1", "to" => "AG2", "state" => "open"}
                   ]
                 }
               ],
               "alerts" => [%{"type" => "security.join_failed", "payload" => %{"ip" => _}}]
             } = authed(s.t2) |> get(~p"/v1/inbox") |> json_response(200)

      assert %{"alerts" => [], "threads" => [_]} =
               authed(s.t2) |> get(~p"/v1/inbox") |> json_response(200)

      assert %{"empty" => false, "threads" => [], "alerts" => [_]} =
               authed(s.t1) |> get(~p"/v1/inbox") |> json_response(200)
    end
  end

  describe "POST /v1/threads/:id/cancel" do
    test "the target sees the cancellation in its inbox once", %{s: s} do
      open(s)
      authed(s.t2) |> post(~p"/v1/threads/T1/claim", %{}) |> json_response(200)

      assert %{"cancelled" => "T1.1", "note" => "T1.2", "thread" => %{"status" => "answered"}} =
               authed(s.t1)
               |> post(~p"/v1/threads/T1/cancel", %{
                 "request_id" => "T1.1",
                 "reason" => "Not needed"
               })
               |> json_response(200)

      assert %{
               "empty" => false,
               "threads" => [],
               "cancelled" => [
                 %{
                   "thread" => "T1",
                   "request" => "T1.1",
                   "cancelled_by" => "AG1",
                   "claimed_by" => "AG2",
                   "reason" => "Not needed",
                   "seq" => _
                 }
               ]
             } = authed(s.t2) |> get(~p"/v1/inbox") |> json_response(200)

      assert %{"empty" => true, "cancelled" => []} =
               authed(s.t2) |> get(~p"/v1/inbox") |> json_response(200)

      assert %{"error" => %{"code" => "conflict"}} =
               authed(s.t1)
               |> post(~p"/v1/threads/T1/cancel", %{"request_id" => "T1.1"})
               |> json_response(409)

      assert %{"error" => %{"code" => "forbidden"}} =
               authed(s.t2)
               |> post(~p"/v1/threads/T1/cancel", %{"request_id" => "T1.1"})
               |> json_response(403)
    end
  end

  describe "Idempotency-Key" do
    defp keyed(token, key), do: token |> authed() |> put_req_header("idempotency-key", key)

    test "a retry replays the first response and creates nothing", %{s: s} do
      body = %{"title" => "Once", "body" => "b", "to" => "AG2"}
      path = ~p"/v1/sessions/#{s.code}/threads"

      first = keyed(s.t1, "k-1") |> post(path, body)
      assert %{"id" => "T1"} = json_response(first, 201)
      assert get_resp_header(first, "idempotent-replayed") == []

      again = keyed(s.t1, "k-1") |> post(path, Map.new(Enum.reverse(Map.to_list(body))))
      assert json_response(again, 201) == json_response(first, 201)
      assert get_resp_header(again, "idempotent-replayed") == ["true"]
      assert Repo.aggregate(Thread, :count) == 1
    end

    test "the same key with another body is a 422; keys are per agent", %{s: s} do
      path = ~p"/v1/sessions/#{s.code}/threads"
      keyed(s.t1, "k-2") |> post(path, %{"title" => "a", "body" => "b", "to" => "AG2"})

      assert %{"error" => %{"code" => "invalid_request"}} =
               keyed(s.t1, "k-2")
               |> post(path, %{"title" => "z", "body" => "b", "to" => "AG2"})
               |> json_response(422)

      assert %{"id" => "T2"} =
               keyed(s.t2, "k-2")
               |> post(path, %{"title" => "z", "body" => "b", "to" => "AG1"})
               |> json_response(201)
    end

    test "errors other than 5xx are stored too", %{s: s} do
      open(s)
      keyed(s.t2, "k-3") |> post(~p"/v1/threads/T1/finish", %{}) |> json_response(403)

      assert %{"error" => %{"code" => "forbidden"}} =
               keyed(s.t2, "k-3") |> post(~p"/v1/threads/T1/finish", %{}) |> json_response(403)

      assert Repo.aggregate(IdempotencyKey, :count) == 1
    end

    test "an empty or too long key is a 400", %{s: s} do
      for key <- [" ", String.duplicate("k", 101)] do
        assert %{"error" => %{"code" => "invalid_request"}} =
                 keyed(s.t1, key)
                 |> post(~p"/v1/sessions/#{s.code}/unlock", %{})
                 |> json_response(400)
      end
    end

    test "a copy of a request still in flight is a 409", %{s: s} do
      agent = Sessions.get_agent_by_token(s.t1)
      assert Idempotency.begin(agent, "k-4") == :ok

      assert %{"error" => %{"code" => "conflict"}} =
               keyed(s.t1, "k-4")
               |> post(~p"/v1/sessions/#{s.code}/unlock", %{})
               |> json_response(409)

      Idempotency.finish(agent, "k-4")

      assert %{"unlocked" => false} =
               keyed(s.t1, "k-4")
               |> post(~p"/v1/sessions/#{s.code}/unlock", %{})
               |> json_response(200)
    end

    test "keys older than a day are purged", %{s: s} do
      keyed(s.t1, "k-5") |> post(~p"/v1/sessions/#{s.code}/unlock", %{}) |> json_response(200)
      assert Idempotency.purge() == 0
      assert Idempotency.purge(DateTime.add(DateTime.utc_now(), 25 * 3600)) == 1
    end
  end
end
