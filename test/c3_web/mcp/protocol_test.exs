defmodule C3Web.MCP.ProtocolTest do
  @moduledoc "The transport side of `/mcp`: Streamable HTTP `2026-07-28`, and the legacy fallback."
  use C3Web.ConnCase, async: false

  import C3Web.MCPHelpers

  defp put_config(key, value) do
    previous = Application.fetch_env(:c3, key)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:c3, key, v)
        :error -> Application.delete_env(:c3, key)
      end
    end)

    Application.put_env(:c3, key, value)
  end

  defp fresh_conn, do: with_ip(build_conn(), unique_ip())

  describe "2026-07-28" do
    test "server/discover names the versions, the tools capability and caching hints", %{
      conn: conn
    } do
      assert %{"id" => 1, "result" => result} =
               conn |> mcp("server/discover") |> json_response(200)

      assert %{
               "resultType" => "complete",
               "supportedVersions" => ["2026-07-28" | _],
               "capabilities" => %{"tools" => %{}},
               "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => "c3"}},
               "ttlMs" => ttl,
               "cacheScope" => "public"
             } = result

      assert is_integer(ttl) and ttl >= 0
      assert result["instructions"] =~ "token"
    end

    test "tools/list is stable and every tool but create/join takes the token", %{conn: conn} do
      %{"result" => %{"tools" => tools, "ttlMs" => _, "cacheScope" => "public"}} =
        conn |> mcp("tools/list") |> json_response(200)

      names = Enum.map(tools, & &1["name"])

      assert names ==
               (fresh_conn() |> mcp("tools/list") |> json_response(200))["result"]["tools"]
               |> Enum.map(& &1["name"])

      assert ~w(c3_create_session c3_join_session c3_inbox c3_get_thread c3_open_thread c3_post
                c3_claim c3_finish c3_reopen c3_leave c3_close_session) -- names == []

      for %{"name" => name, "inputSchema" => schema} <- tools,
          name not in ~w(c3_create_session c3_join_session) do
        assert "token" in schema["required"], "#{name} does not require the token"
      end
    end

    test "ping answers an empty result", %{conn: conn} do
      assert %{"result" => %{"resultType" => "complete"}} =
               conn |> mcp("ping") |> json_response(200)
    end

    test "headers that do not match the body are a 400 HeaderMismatch", %{conn: conn} do
      for headers <- [
            %{"mcp-method" => nil},
            %{"mcp-method" => "tools/list"},
            %{"mcp-name" => nil},
            %{"mcp-name" => "c3_session"}
          ] do
        body =
          fresh_conn()
          |> mcp("tools/call", %{"name" => "c3_inbox", "arguments" => %{}}, headers)
          |> json_response(400)

        assert %{"error" => %{"code" => -32_020}} = body, inspect(headers)
      end

      # The _meta version must match the header.
      assert %{"error" => %{"code" => -32_020}} =
               conn
               |> mcp("tools/list", %{"_meta" => meta("2025-11-25")})
               |> json_response(400)
    end

    test "a Base64-encoded Mcp-Name is decoded before the comparison", %{conn: conn} do
      encoded = "=?base64?" <> Base.encode64("c3_create_session") <> "?="

      assert {201, %{"agent" => %{"name" => "AG1"}}} =
               conn
               |> mcp("tools/call", %{"name" => "c3_create_session", "arguments" => %{}}, %{
                 "mcp-name" => encoded
               })
               |> json_response(200)
               |> then(&{&1["result"]["_meta"]["c3/status"], &1["result"]["structuredContent"]})
    end

    test "an unknown version is a 400 UnsupportedProtocolVersion with the supported list", %{
      conn: conn
    } do
      body =
        conn
        |> mcp("tools/list", %{"_meta" => meta("1900-01-01")}, %{
          "mcp-protocol-version" => "1900-01-01"
        })
        |> json_response(400)

      assert %{
               "error" => %{
                 "code" => -32_022,
                 "data" => %{"requested" => "1900-01-01", "supported" => ["2026-07-28" | _]}
               }
             } = body
    end

    test "an unknown method is a 404 with -32601", %{conn: conn} do
      assert %{"error" => %{"code" => -32_601}} =
               conn |> mcp("resources/list") |> json_response(404)
    end

    test "an unknown tool or arguments that are not an object are -32602", %{conn: conn} do
      assert %{"error" => %{"code" => -32_602}} =
               conn
               |> mcp("tools/call", %{"name" => "c3_nope", "arguments" => %{}})
               |> json_response(200)

      assert %{"error" => %{"code" => -32_602}} =
               fresh_conn()
               |> mcp("tools/call", %{"name" => "c3_inbox", "arguments" => "token"})
               |> json_response(200)
    end

    test "a notification is 202 without a body, a batch is a 400", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/x"}))

      assert response(conn, 202) == ""

      batch =
        fresh_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", Jason.encode!([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}]))

      assert %{"error" => %{"code" => -32_600}} = json_response(batch, 400)
    end

    test "GET and DELETE are 405, even asking for an event stream", %{conn: conn} do
      conn = conn |> put_req_header("accept", "text/event-stream") |> get("/mcp")
      assert response(conn, 405) == ""
      assert get_resp_header(conn, "allow") == ["POST"]
      assert fresh_conn() |> delete("/mcp") |> response(405)
    end

    test "no session id is minted or echoed", %{conn: conn} do
      conn = conn |> put_req_header("mcp-session-id", "abc") |> mcp("ping")
      assert get_resp_header(conn, "mcp-session-id") == []
    end
  end

  describe "Origin" do
    test "a request with a foreign Origin is a 403, one without passes", %{conn: conn} do
      foreign = conn |> put_req_header("origin", "https://evil.example") |> mcp("ping")
      assert %{"error" => %{"code" => -32_600}} = json_response(foreign, 403)

      assert fresh_conn() |> mcp("ping") |> json_response(200)
    end

    test "an allowed Origin passes" do
      put_config(:mcp_allowed_origins, ["https://app.example.com"])

      assert fresh_conn()
             |> put_req_header("origin", "https://app.example.com")
             |> mcp("ping")
             |> json_response(200)
    end
  end

  describe "legacy clients" do
    defp legacy(conn, method, params, version \\ "2025-11-25") do
      conn
      |> put_req_header("content-type", "application/json")
      |> then(&if version, do: put_req_header(&1, "mcp-protocol-version", version), else: &1)
      |> post(
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params})
      )
    end

    test "initialize answers a legacy version without a session", %{conn: conn} do
      conn = legacy(conn, "initialize", %{"protocolVersion" => "2025-06-18"}, nil)

      assert %{
               "result" => %{
                 "protocolVersion" => "2025-06-18",
                 "capabilities" => %{"tools" => %{}},
                 "serverInfo" => %{"name" => "c3"}
               }
             } = json_response(conn, 200)

      assert get_resp_header(conn, "mcp-session-id") == []

      # A version C3 does not know gets the newest legacy one.
      assert %{"result" => %{"protocolVersion" => "2025-11-25"}} =
               fresh_conn()
               |> legacy("initialize", %{"protocolVersion" => "2024-11-05"}, nil)
               |> json_response(200)
    end

    test "tools work without _meta nor the mirrored headers", %{conn: conn} do
      body =
        conn
        |> legacy("tools/call", %{"name" => "c3_create_session", "arguments" => %{}})
        |> json_response(200)

      assert %{"result" => %{"isError" => false, "structuredContent" => %{"secret" => _}}} = body
      refute Map.has_key?(body["result"], "resultType")

      # Without the header it is 2025-03-26, from before the header existed.
      assert %{"result" => %{"tools" => [_ | _]}} =
               fresh_conn() |> legacy("tools/list", %{}, nil) |> json_response(200)
    end

    test "a response or a notification from the client is 202", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 3, "result" => %{}}))

      assert response(conn, 202) == ""
    end
  end

  describe "the REST guards hold through MCP" do
    test "a tool call counts once against the IP limit" do
      put_config(:rate_limit_ip, 3)
      ip = unique_ip()
      conn = fn -> with_ip(build_conn(), ip) end

      {201, %{"agent" => %{"token" => token}}} = tool(conn.(), "c3_create_session")
      {200, _} = tool(conn.(), "c3_inbox", %{"token" => token})
      {200, _} = tool(conn.(), "c3_inbox", %{"token" => token})

      limited =
        mcp(conn.(), "tools/call", %{"name" => "c3_inbox", "arguments" => %{"token" => token}})

      assert %{"error" => %{"code" => "rate_limited"}} = json_response(limited, 429)
    end

    test "tool calls count against the token limit, as a tool error" do
      {201, %{"agent" => %{"token" => token}}} = tool(fresh_conn(), "c3_create_session")
      put_config(:rate_limit_token, 2)

      {200, _} = tool(fresh_conn(), "c3_inbox", %{"token" => token})
      {200, _} = tool(fresh_conn(), "c3_inbox", %{"token" => token})

      assert {429, %{"error" => %{"code" => "rate_limited"}}} =
               tool(fresh_conn(), "c3_inbox", %{"token" => token})
    end

    test "a wrong secret by MCP bans the caller's IP for REST too" do
      put_config(:secret_tolerance, 0)
      {201, %{"session_code" => code}} = tool(fresh_conn(), "c3_create_session")
      ip = unique_ip()

      assert {403, %{"error" => %{"code" => "invalid_secret"}}} =
               tool(with_ip(build_conn(), ip), "c3_join_session", %{
                 "session_code" => code,
                 "secret" => "000000"
               })

      assert %{"error" => %{"code" => "ip_banned"}} =
               with_ip(build_conn(), ip)
               |> post(~p"/v1/sessions", %{})
               |> json_response(403)
    end

    test "a tool call is activity on the session; c3_events is not" do
      {201, %{"session_code" => code, "agent" => %{"token" => token}}} =
        tool(fresh_conn(), "c3_create_session")

      session = C3.Sessions.get_session_by_code(code)
      old = DateTime.add(DateTime.utc_now(), -3600)
      C3.Repo.update_all(C3.Sessions.Session, set: [last_activity_at: old])

      {200, _} = tool(fresh_conn(), "c3_events", %{"token" => token})
      assert C3.Repo.reload(session).last_activity_at == DateTime.truncate(old, :microsecond)

      {200, _} = tool(fresh_conn(), "c3_inbox", %{"token" => token})
      assert DateTime.compare(C3.Repo.reload(session).last_activity_at, old) == :gt
    end

    test "the secret and the tokens are filtered out of the logged params" do
      filtered =
        Phoenix.Logger.filter_values(%{
          "params" => %{"arguments" => %{"token" => "c3_x", "secret" => "123456", "body" => "hi"}}
        })

      assert filtered["params"]["arguments"] == %{
               "token" => "[FILTERED]",
               "secret" => "[FILTERED]",
               "body" => "hi"
             }
    end
  end
end
