defmodule C3Web.MCP.ParityTest do
  @moduledoc """
  The spec's MCP test: every tool against the same scenario as the REST API — same results,
  same errors. The scenario runs twice, once through `/v1` and once through `/mcp`, each from
  its own IP, and the two transcripts must be equal once the values that differ between two
  runs (codes, secrets, tokens, times, IPs) are masked.
  """
  use C3Web.ConnCase

  import C3Web.MCPHelpers

  # The REST route of each tool, written out here so the test does not trust
  # `C3Web.MCP.Tools` to map them.
  @routes %{
    "c3_create_session" => {:post, "/sessions"},
    "c3_join_session" => {:post, "/sessions/:code/join"},
    "c3_session" => {:get, "/sessions/:code"},
    "c3_inbox" => {:get, "/inbox"},
    "c3_list_threads" => {:get, "/sessions/:code/threads"},
    "c3_get_thread" => {:get, "/threads/:thread"},
    "c3_open_thread" => {:post, "/sessions/:code/threads"},
    "c3_post" => {:post, "/threads/:thread/messages"},
    "c3_claim" => {:post, "/threads/:thread/claim"},
    "c3_cancel" => {:post, "/threads/:thread/cancel"},
    "c3_finish" => {:post, "/threads/:thread/finish"},
    "c3_reopen" => {:post, "/threads/:thread/reopen"},
    "c3_events" => {:get, "/sessions/:code/events"},
    "c3_unlock" => {:post, "/sessions/:code/unlock"},
    "c3_rotate_secret" => {:post, "/sessions/:code/rotate-secret"},
    "c3_get_attachment" => {:get, "/attachments/:attachment"},
    "c3_leave" => {:post, "/sessions/:code/leave"},
    "c3_close_session" => {:post, "/sessions/:code/close"}
  }

  @masked ~w(session_code secret token at created_at expires_at last_activity_at
             last_seen_at joined_at last_message_at finished_at resolved_at closed_at closes_at
             banned_until ip subject)

  # Each step: who calls (:a, :b, or :none for no token), the tool and its arguments. `:code`,
  # `:secret` and a token as an argument are filled in from what earlier steps returned.
  @scenario [
    {:none, "c3_create_session", %{"label" => "parity", "agent_label" => "fedora"}},
    {:none, "c3_join_session",
     %{"session_code" => :code, "secret" => :secret, "agent_label" => "vm"}},
    {:a, "c3_session", %{}},
    {:a, "c3_open_thread", %{"title" => "Deploy?", "body" => "Can you deploy?", "to" => ["AG2"]}},
    {:a, "c3_open_thread", %{"title" => "No body"}},
    {:b, "c3_inbox", %{}},
    {:a, "c3_claim", %{"thread" => "T1"}},
    {:b, "c3_claim", %{"thread" => "T1"}},
    {:b, "c3_claim", %{"thread" => "T1", "request_id" => "T1.1"}},
    {:b, "c3_post", %{"thread" => "T1", "kind" => "response", "body" => "Deployed."}},
    {:b, "c3_post",
     %{"thread" => "T1", "kind" => "response", "body" => "Again", "reply_to" => "T1.1"}},
    {:a, "c3_get_thread", %{"thread" => "T1"}},
    {:a, "c3_get_thread", %{"thread" => "T1", "since" => "T1.1"}},
    {:a, "c3_get_thread", %{"thread" => "T99"}},
    {:a, "c3_post",
     %{"thread" => "T1", "kind" => "request", "body" => "And the docs?", "to" => "AG2"}},
    {:a, "c3_post",
     %{"thread" => "T1", "kind" => "note", "body" => "fyi", "idempotency_key" => "k1"}},
    {:a, "c3_post",
     %{"thread" => "T1", "kind" => "note", "body" => "fyi", "idempotency_key" => "k1"}},
    {:a, "c3_post",
     %{"thread" => "T1", "kind" => "note", "body" => "other", "idempotency_key" => "k1"}},
    {:a, "c3_post", %{"thread" => "T1", "kind" => "shout", "body" => "?"}},
    {:b, "c3_cancel", %{"thread" => "T1", "request_id" => "T1.3"}},
    {:a, "c3_cancel", %{"thread" => "T1", "request_id" => "T1.3", "reason" => "Not needed"}},
    {:b, "c3_inbox", %{}},
    {:b, "c3_finish", %{"thread" => "T1"}},
    {:a, "c3_finish", %{"thread" => "T1"}},
    {:a, "c3_post", %{"thread" => "T1", "kind" => "note", "body" => "late"}},
    {:a, "c3_reopen", %{"thread" => "T1"}},
    {:a, "c3_list_threads", %{"status" => "pending"}},
    {:a, "c3_list_threads", %{"status" => "bogus"}},
    {:a, "c3_list_threads", %{"awaiting" => "me"}},
    {:a, "c3_events", %{"after" => 0, "limit" => 5}},
    {:a, "c3_events", %{"after" => 3}},
    {:b, "c3_unlock", %{}},
    {:a, "c3_post",
     %{
       "thread" => "T1",
       "kind" => "note",
       "body" => "the log",
       "attachments" => [%{"filename" => "run.log", "text" => "ok\n"}]
     }},
    {:a, "c3_post",
     %{
       "thread" => "T1",
       "kind" => "note",
       "body" => "bad",
       "attachments" => [%{"filename" => "x", "base64" => "%%%"}]
     }},
    {:b, "c3_get_attachment", %{"attachment_id" => :attachment}},
    {:b, "c3_get_attachment", %{"attachment_id" => 999_999_999}},
    {:a, "c3_rotate_secret", %{}},
    {:none, "c3_inbox", %{}},
    {:bad, "c3_inbox", %{}},
    {:none, "c3_join_session", %{"session_code" => :code, "secret" => "000000"}},
    {:none, "c3_join_session", %{"session_code" => :code, "secret" => :secret}},
    {:a, "c3_inbox", %{}},
    {:b, "c3_leave", %{}},
    {:b, "c3_inbox", %{}},
    {:a, "c3_close_session", %{}},
    {:a, "c3_inbox", %{}},
    {:a, "c3_get_thread", %{"thread" => "T1"}}
  ]

  test "every tool answers what its REST route answers" do
    # The script expects a ban at the first wrong secret.
    previous = Application.fetch_env(:c3, :secret_tolerance)
    Application.put_env(:c3, :secret_tolerance, 0)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:c3, :secret_tolerance, v)
        :error -> Application.delete_env(:c3, :secret_tolerance)
      end
    end)

    rest = run(&rest_call/3)
    mcp = run(&tool/3)

    for {{step, rest_result}, {step, mcp_result}} <- Enum.zip(rest, mcp) do
      assert {step, mcp_result} == {step, rest_result}
    end

    # The scenario exercised the error codes, not only the happy path.
    codes = for {_, {_, %{"error" => %{"code" => code}}}} <- rest, uniq: true, do: code

    assert Enum.sort(codes) ==
             ~w(conflict forbidden invalid_request invalid_secret ip_banned not_found
                session_closed unauthorized)
  end

  defp run(call) do
    ip = unique_ip()

    {transcript, _ctx} =
      @scenario
      |> Enum.with_index(1)
      |> Enum.map_reduce(%{}, fn {{who, name, args} = step, index}, ctx ->
        args = fill(args, who, ctx)
        {status, body} = call.(with_ip(build_conn(), ip), name, args)
        {{{index, step}, {status, mask(body)}}, learn(ctx, name, body)}
      end)

    transcript
  end

  defp fill(args, who, ctx) do
    args =
      Map.new(args, fn
        {key, value} when is_atom(value) -> {key, Map.fetch!(ctx, value)}
        pair -> pair
      end)

    case who do
      :none -> args
      :bad -> Map.put(args, "token", "c3_not-a-token")
      who -> Map.put(args, "token", Map.fetch!(ctx, who))
    end
  end

  defp learn(ctx, "c3_create_session", %{"session_code" => code, "secret" => secret} = body),
    do: Map.merge(ctx, %{code: code, secret: secret, a: body["agent"]["token"]})

  defp learn(ctx, "c3_join_session", %{"agent" => %{"name" => "AG2", "token" => token}}),
    do: Map.put(ctx, :b, token)

  defp learn(ctx, "c3_post", %{"messages" => [%{"attachments" => [%{"id" => id} | _]} | _]}),
    do: Map.put(ctx, :attachment, id)

  defp learn(ctx, _name, _body), do: ctx

  defp rest_call(conn, name, args) do
    {method, route} = Map.fetch!(@routes, name)
    {token, args} = Map.pop(args, "token")
    {key, args} = Map.pop(args, "idempotency_key")
    {code, args} = Map.pop(args, "session_code")
    {thread, args} = Map.pop(args, "thread")
    {attachment, args} = Map.pop(args, "attachment_id")
    code = code || (route =~ ":code" && code_of(token))

    path =
      "/v1" <>
        (route
         |> String.replace(":code", to_string(code))
         |> String.replace(":thread", to_string(thread))
         |> String.replace(":attachment", to_string(attachment)))

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> then(&if token, do: put_req_header(&1, "authorization", "Bearer " <> token), else: &1)
      |> then(&if key, do: put_req_header(&1, "idempotency-key", key), else: &1)

    conn =
      case method do
        :get -> get(conn, path, query(name, args))
        :post -> post(conn, path, args)
      end

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp query("c3_events", args), do: Map.put(args, "wait", 0)
  defp query("c3_get_attachment", args), do: Map.put(args, "format", "json")
  defp query(_name, args), do: args

  # The session code a token belongs to, as the agent would remember it.
  defp code_of(token) do
    case token && C3.Sessions.get_agent_by_token(token) do
      %{session: session} -> session.code
      _ -> "-"
    end
  end

  defp mask(%{} = map) do
    Map.new(map, fn
      {key, value} when key in @masked and not is_nil(value) -> {key, "<masked>"}
      # An attachment's id is a row id: it differs between the two runs.
      {"id", value} when is_integer(value) -> {"id", "<masked>"}
      {key, value} -> {key, mask(value)}
    end)
  end

  defp mask(list) when is_list(list), do: Enum.map(list, &mask/1)
  # A session code under any other key (`session.code`, an event payload).
  defp mask("C3-" <> _), do: "<masked>"
  defp mask(value), do: value
end
