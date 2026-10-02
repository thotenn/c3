defmodule C3Web.V1.F8ControllerTest do
  @moduledoc "The REST side of attachments, the secret rotation and `/metrics`."
  # Attachments live in one shared directory, and one test swaps the metrics token.
  use C3Web.ConnCase, async: false

  alias C3.{Events, Idempotency, Repo, Sessions}
  alias C3.Sessions.IdempotencyKey

  defp fresh_conn, do: with_ip(build_conn(), unique_ip())

  defp authed(token), do: put_req_header(fresh_conn(), "authorization", "Bearer " <> token)

  defp join(code, secret, conn \\ fresh_conn()) do
    post(conn, ~p"/v1/sessions/#{code}/join", %{"secret" => secret})
  end

  defp session! do
    created = fresh_conn() |> post(~p"/v1/sessions", %{}) |> json_response(201)
    %{"session_code" => code, "secret" => secret, "agent" => %{"token" => t1}} = created
    %{"agent" => %{"token" => t2}} = join(code, secret) |> json_response(201)
    %{code: code, secret: secret, t1: t1, t2: t2}
  end

  defp put_config(key, value) do
    previous = Application.get_env(:c3, key)

    Application.put_env(:c3, key, value)
    # Unset before: delete it again, or `C3.Config.get/1` would read nil instead of the default.
    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:c3, key),
        else: Application.put_env(:c3, key, previous)
    end)
  end

  defp event_types(code) do
    code |> Sessions.get_session_by_code() |> Events.list_after(0) |> Enum.map(& &1.type)
  end

  setup do: %{s: session!()}

  describe "attachments" do
    test "posted inline, listed on the message, downloaded as an attachment", %{s: s} do
      body = %{
        "title" => "Logs",
        "body" => "See attached",
        "to" => "AG2",
        "attachments" => [
          %{"filename" => "build.log", "text" => "line 1\nline 2\n"},
          %{"filename" => "<script>.html", "base64" => Base.encode64("<script>x</script>")}
        ]
      }

      assert %{
               "messages" => [
                 %{
                   "attachments" => [
                     %{"id" => log_id, "filename" => "build.log", "size_bytes" => 14},
                     %{"id" => html_id, "content_type" => "application/octet-stream"}
                   ]
                 }
               ]
             } =
               authed(s.t1)
               |> post(~p"/v1/sessions/#{s.code}/threads", body)
               |> json_response(201)

      conn = authed(s.t2) |> get(~p"/v1/attachments/#{log_id}")
      assert conn.status == 200
      assert conn.resp_body == "line 1\nline 2\n"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(attachment; filename="build.log")
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert ["default-src 'none'; sandbox"] = get_resp_header(conn, "content-security-policy")
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"

      # A file that would be HTML is still a download, never rendered.
      conn = authed(s.t2) |> get(~p"/v1/attachments/#{html_id}")
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment;"

      # The same ETag is a 304.
      [etag] = get_resp_header(conn, "etag")

      assert authed(s.t2)
             |> put_req_header("if-none-match", etag)
             |> get(~p"/v1/attachments/#{html_id}")
             |> Map.fetch!(:status) == 304

      assert %{"encoding" => "text", "content" => "line 1\nline 2\n", "filename" => "build.log"} =
               authed(s.t1)
               |> get(~p"/v1/attachments/#{log_id}?format=json")
               |> json_response(200)
    end

    test "a thread shows them, other sessions cannot read them", %{s: s} do
      authed(s.t1)
      |> post(~p"/v1/sessions/#{s.code}/threads", %{
        "title" => "t",
        "body" => "b",
        "attachments" => [%{"filename" => "a.txt", "text" => "x"}]
      })
      |> json_response(201)

      assert %{"messages" => [%{"attachments" => [%{"id" => id}]}]} =
               authed(s.t2) |> get(~p"/v1/threads/T1") |> json_response(200)

      other = session!()

      assert %{"error" => %{"code" => "not_found"}} =
               authed(other.t1) |> get(~p"/v1/attachments/#{id}") |> json_response(404)

      assert fresh_conn() |> get(~p"/v1/attachments/#{id}") |> json_response(401)
    end

    test "limits are 413 and malformed attachments are 422", %{s: s} do
      put_config(:attachment_max_bytes, 4)

      post = fn attachments ->
        authed(s.t1)
        |> post(~p"/v1/sessions/#{s.code}/threads", %{
          "title" => "t",
          "body" => "b",
          "attachments" => attachments
        })
      end

      assert %{"error" => %{"code" => "too_large"}} =
               post.([%{"filename" => "a", "text" => "12345"}]) |> json_response(413)

      assert %{"error" => %{"code" => "invalid_request", "details" => details}} =
               post.([%{"filename" => "a", "base64" => "%%%"}]) |> json_response(422)

      assert Map.has_key?(details, "attachments.0.base64")
    end
  end

  describe "POST /v1/sessions/{code}/rotate-secret" do
    test "the old number stops working, agents inside keep their tokens", %{s: s} do
      assert %{"secret" => new, "unlocked" => false, "joins_locked" => false} =
               authed(s.t2)
               |> post(~p"/v1/sessions/#{s.code}/rotate-secret")
               |> json_response(200)

      assert new =~ ~r/^\d{6}$/
      assert :session_secret_rotated in event_types(s.code)

      [event] =
        for e <- Sessions.get_session_by_code(s.code) |> Events.list_after(0),
            e.type == :session_secret_rotated,
            do: e

      assert event.payload == %{"by" => "AG2", "unlocked" => false}
      refute inspect(event.payload) =~ new

      # Old number: a wrong secret like any other (403 + ban), unless it equals the new one.
      if new != s.secret do
        assert %{"error" => %{"code" => "invalid_secret"}} =
                 join(s.code, s.secret) |> json_response(403)
      end

      assert %{"agent" => %{"name" => "AG3"}} = join(s.code, new) |> json_response(201)
      assert authed(s.t1) |> get(~p"/v1/sessions/#{s.code}") |> json_response(200)
    end

    test "it lifts a join lock, and older failures do not relock", %{s: s} do
      for _ <- 1..3, do: join(s.code, wrong(s.secret)) |> json_response(403)
      assert Sessions.get_session_by_code(s.code).joins_locked_at

      assert %{"secret" => new, "unlocked" => true} =
               authed(s.t1)
               |> post(~p"/v1/sessions/#{s.code}/rotate-secret")
               |> json_response(200)

      refute Sessions.get_session_by_code(s.code).joins_locked_at
      join(s.code, wrong(new)) |> json_response(403)
      refute Sessions.get_session_by_code(s.code).joins_locked_at
    end

    test "an Idempotency-Key is not honored: the new number is never stored", %{s: s} do
      rotate = fn ->
        authed(s.t1)
        |> put_req_header("idempotency-key", "rotate-1")
        |> post(~p"/v1/sessions/#{s.code}/rotate-secret")
      end

      conn = rotate.()
      assert %{"secret" => _} = json_response(conn, 200)
      assert get_resp_header(conn, "idempotent-replayed") == []
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert %{"secret" => _} = rotate.() |> json_response(200)
      assert Repo.aggregate(IdempotencyKey, :count) == 0
      assert is_nil(Idempotency.lookup(Sessions.get_agent_by_token(s.t1), "rotate-1"))
    end

    test "on a closed session it is a 410", %{s: s} do
      authed(s.t1) |> post(~p"/v1/sessions/#{s.code}/close") |> json_response(200)

      assert %{"error" => %{"code" => "session_closed"}} =
               authed(s.t2)
               |> post(~p"/v1/sessions/#{s.code}/rotate-secret")
               |> json_response(410)
    end
  end

  describe "GET /metrics" do
    test "a 404 without C3_METRICS_TOKEN" do
      put_config(:metrics_token, nil)
      assert fresh_conn() |> get(~p"/metrics") |> json_response(404)
    end

    test "Prometheus text for the bearer of the token, 401 for anyone else", %{s: s} do
      token = String.duplicate("m", 32)
      put_config(:metrics_token, token)

      assert fresh_conn() |> get(~p"/metrics") |> json_response(401)

      assert fresh_conn()
             |> put_req_header("authorization", "Bearer wrong")
             |> get(~p"/metrics")
             |> json_response(401)

      # A long-poll that times out and a failed join land in the counters.
      authed(s.t1)
      |> get(~p"/v1/sessions/#{s.code}/events?after=999&wait=1")
      |> json_response(200)

      join(s.code, wrong(s.secret)) |> json_response(403)

      conn =
        fresh_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(~p"/metrics")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
      text = conn.resp_body

      for name <- ~w(c3_sessions_created_total c3_sessions_open c3_agents_active
                     c3_ip_bans_active c3_attachments_bytes) do
        assert text =~ "# TYPE #{name}"
      end

      assert text =~ ~s(c3_join_failures_total{reason="invalid_secret"})
      assert text =~ ~s(c3_ip_bans_total{reason="invalid_secret"})
      assert text =~ ~s(c3_long_poll_duration_seconds_bucket{outcome="timeout",le="+Inf"})
      assert text =~ ~s(c3_long_poll_duration_seconds_count{outcome="timeout"})
    end
  end

  defp wrong(secret) do
    secret
    |> String.to_integer()
    |> Kernel.+(1)
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
