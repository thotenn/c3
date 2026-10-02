defmodule C3Web.AdminLiveTest do
  use C3Web.ConnCase

  import Phoenix.LiveViewTest

  @moduletag :capture_log

  alias C3.{Admin, Config, Security, Sessions, Threads}

  defp meta, do: %{ip: "198.51.100.#{rem(System.unique_integer([:positive]), 250)}"}

  defp log_in(conn) do
    conn
    |> post(~p"/admin/login", %{"login" => %{"token" => Config.get(:admin_token)}})
    |> recycle()
    |> with_ip(unique_ip())
  end

  defp two_agents! do
    {:ok, %{session: session, agent: ag1, secret: secret}} =
      Sessions.create_session(%{"label" => "pairing"}, meta())

    {:ok, %{agent: ag2, token: t2}} =
      Sessions.join_session(session.code, %{"secret" => secret}, meta())

    %{session: session, ag1: ag1, ag2: ag2, t2: t2}
  end

  describe "login" do
    test "/admin is a 404 while C3_ADMIN_TOKEN is unset", %{conn: conn} do
      previous = Application.get_env(:c3, :admin_token)
      Application.put_env(:c3, :admin_token, nil)
      on_exit(fn -> Application.put_env(:c3, :admin_token, previous) end)

      assert conn |> get(~p"/admin/login") |> html_response(404)
      assert build_conn() |> get(~p"/admin") |> html_response(404)
    end

    test "without a login, the admin pages send to the login form", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin")

      html = conn |> get(~p"/admin/login") |> html_response(200)
      assert html =~ ~s(id="admin-login-form")
    end

    test "a wrong token is a 401 and no login", %{conn: conn} do
      conn = post(conn, ~p"/admin/login", %{"login" => %{"token" => "nope"}})
      assert html_response(conn, 401) =~ "Invalid admin token"

      assert {:error, {:redirect, %{to: "/admin/login"}}} =
               conn |> recycle() |> live(~p"/admin")
    end

    test "the right token logs in; the cookie holds a fingerprint, not the token",
         %{conn: conn} do
      conn = post(conn, ~p"/admin/login", %{"login" => %{"token" => Config.get(:admin_token)}})
      assert redirected_to(conn) == "/admin"
      assert get_session(conn, "c3_admin") == Admin.fingerprint()
      refute get_session(conn, "c3_admin") == Config.get(:admin_token)

      assert {:ok, _view, _html} = conn |> recycle() |> live(~p"/admin")
    end

    test "logout drops the login", %{conn: conn} do
      conn = conn |> log_in() |> delete(~p"/admin/logout")
      assert redirected_to(conn) == "/admin/login"

      assert {:error, {:redirect, %{to: "/admin/login"}}} =
               conn |> recycle() |> live(~p"/admin")
    end

    test "the login is limited per IP", %{conn: conn} do
      ip = unique_ip()

      for _ <- 1..10 do
        conn |> with_ip(ip) |> post(~p"/admin/login", %{"login" => %{"token" => "x"}})
      end

      conn = conn |> with_ip(ip) |> post(~p"/admin/login", %{"login" => %{"token" => "x"}})
      assert html_response(conn, 429) =~ "Too many attempts"
    end
  end

  describe "sessions list" do
    setup %{conn: conn}, do: %{conn: log_in(conn)}

    test "shows the sessions and refreshes on a new one", %{conn: conn} do
      %{session: s} = two_agents!()
      {:ok, view, _html} = live(conn, ~p"/admin")
      assert has_element?(view, "#session-#{s.id}", s.code)

      {:ok, %{session: other}} = Sessions.create_session(%{}, meta())
      send(view.pid, :reload)
      assert has_element?(view, "#session-#{other.id}")
    end

    test "unban lifts the ban and drops the row", %{conn: conn} do
      ban = Security.ban("203.0.113.77", :invalid_secret, nil)
      Security.cache_ban(ban)

      {:ok, view, _html} = live(conn, ~p"/admin")
      assert has_element?(view, "#bans-#{ban.id}")

      view |> element("#unban-#{ban.id}") |> render_click()
      refute has_element?(view, "#bans-#{ban.id}")
      assert Security.banned_until("203.0.113.77") == nil
    end
  end

  describe "session detail" do
    setup %{conn: conn}, do: %{conn: log_in(conn)}

    test "shows agents, and new events and threads arrive live", %{conn: conn} do
      %{session: s, ag1: ag1, ag2: ag2} = two_agents!()
      {:ok, view, _html} = live(conn, ~p"/admin/sessions/#{s.code}")

      assert has_element?(view, "#agents-#{ag1.id}")
      assert has_element?(view, "#agents-#{ag2.id}")
      assert has_element?(view, "#events li", "agent.joined")

      {:ok, _} =
        Threads.open_thread(ag1, %{"title" => "Deploy?", "body" => "Can you?", "to" => "AG2"})

      # The announcement inserts the event at once; the thread list follows the debounce.
      assert render(view) =~ "thread.opened"
      send(view.pid, :reload)
      thread = Threads.get_thread(s, 1)
      assert has_element?(view, "#thread-#{thread.id}", "Deploy?")

      view |> element("#thread-#{thread.id} a") |> render_click()
      assert_patch(view, ~p"/admin/sessions/#{s.code}/threads/1")
      assert has_element?(view, "#messages", "Can you?")
    end

    test "revoke: the token stops working and the watcher gets stop", %{conn: conn} do
      %{session: s, ag2: ag2, t2: t2} = two_agents!()
      {:ok, view, _html} = live(conn, ~p"/admin/sessions/#{s.code}")

      view |> element("#revoke-#{ag2.id}") |> render_click()
      refute has_element?(view, "#revoke-#{ag2.id}")
      assert render(view) =~ "agent.revoked"

      authed = fn -> build_conn() |> put_req_header("authorization", "Bearer " <> t2) end
      assert authed.() |> get(~p"/v1/inbox") |> json_response(401)

      [revoked] = C3.Events.list_recent(s, 1)
      assert C3.Watch.line(revoked, ag2) == "stop #{revoked.seq} revoked"
    end

    test "close, then purge", %{conn: conn} do
      %{session: s, t2: t2} = two_agents!()
      {:ok, view, _html} = live(conn, ~p"/admin/sessions/#{s.code}")

      view |> element("#close-session") |> render_click()
      assert has_element?(view, "#purge-session")
      refute has_element?(view, "#close-session")

      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> t2)
             |> get(~p"/v1/inbox")
             |> json_response(410)

      view |> element("#purge-session") |> render_click()
      assert_redirect(view, ~p"/admin")
      assert Sessions.get_session_by_code(s.code) == nil
    end

    test "an unknown code goes back to the list", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin"}}} =
               live(conn, ~p"/admin/sessions/C3-ZZZZ-ZZZZ")
    end
  end
end
