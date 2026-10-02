defmodule C3.AdminTest do
  use C3.DataCase

  alias C3.{Admin, Config, Events, Repo, Security, Sessions, Threads, Watch}
  alias C3.Security.{BanCache, IpBan}
  alias C3.Sessions.{Agent, Session}

  defp meta, do: %{ip: "198.51.100.#{System.unique_integer([:positive]) |> rem(250)}"}

  # AG1 and AG2, with a thread T1 from AG1 to AG2 that AG2 claimed.
  defp session_with_claim! do
    {:ok, %{session: session, agent: ag1, secret: secret}} = Sessions.create_session(%{}, meta())
    {:ok, %{agent: ag2}} = Sessions.join_session(session.code, %{"secret" => secret}, meta())

    {:ok, _} =
      Threads.open_thread(ag1, %{"title" => "Deploy?", "body" => "Can you?", "to" => "AG2"})

    thread = Threads.get_thread(session, 1)
    {:ok, _} = Threads.claim(ag2, thread, %{})
    %{session: session, ag1: ag1, ag2: ag2, thread: thread}
  end

  defp with_admin_token(token) do
    previous = Application.get_env(:c3, :admin_token)
    Application.put_env(:c3, :admin_token, token)
    on_exit(fn -> Application.put_env(:c3, :admin_token, previous) end)
  end

  describe "access" do
    test "the token is checked in constant time and nothing else passes" do
      assert Admin.enabled?()
      assert Admin.valid_token?(Config.get(:admin_token))
      refute Admin.valid_token?("wrong")
      refute Admin.valid_token?(nil)
    end

    test "with no token there is no admin at all" do
      token = Config.get(:admin_token)
      with_admin_token(nil)

      refute Admin.enabled?()
      refute Admin.valid_token?(token)
      assert Admin.fingerprint() == nil
      refute Admin.valid_login?("anything", System.system_time(:second))
    end

    test "a login holds for admin_session_ttl, and rotating the token voids it" do
      fingerprint = Admin.fingerprint()
      now = System.system_time(:second)
      ttl = Config.get(:admin_session_ttl)

      assert Admin.valid_login?(fingerprint, now, now)
      refute Admin.valid_login?(fingerprint, now - ttl, now)
      refute Admin.valid_login?(fingerprint, now + 60, now)

      with_admin_token(String.duplicate("r", 40))
      refute Admin.valid_login?(fingerprint, now, now)
    end

    test "Config.validate! refuses a short admin token" do
      with_admin_token("short")
      assert_raise ArgumentError, ~r/C3_ADMIN_TOKEN/, fn -> Config.validate!() end
    end
  end

  describe "list_sessions/0" do
    test "counts agents and threads, open sessions first" do
      %{session: s} = session_with_claim!()
      {:ok, %{session: closed, agent: a}} = Sessions.create_session(%{}, meta())
      {:ok, _} = Sessions.close(a)

      rows = Admin.list_sessions()
      ids = Enum.map(rows, & &1.session.id)
      assert Enum.find_index(ids, &(&1 == s.id)) < Enum.find_index(ids, &(&1 == closed.id))

      row = Enum.find(rows, &(&1.session.id == s.id))
      assert {row.agents_active, row.agents_total} == {2, 2}
      assert {row.threads_total, row.threads_open} == {1, 1}

      closed_row = Enum.find(rows, &(&1.session.id == closed.id))
      assert {closed_row.agents_active, closed_row.threads_total} == {0, 0}
    end
  end

  describe "close_session/1" do
    test "closes as admin: tokens revoked, session.closed, the watchers get stop" do
      %{session: s, ag2: ag2} = session_with_claim!()

      assert {:ok, %Session{status: :closed, closed_by: "admin", close_reason: :admin}} =
               Admin.close_session(s)

      assert Enum.all?(Sessions.list_agents(s), &(&1.status == :revoked))
      [event] = Events.list_recent(s, 1)
      assert event.type == :session_closed
      assert event.actor_agent_id == nil
      assert event.payload == %{"closed_by" => "admin", "reason" => "admin"}
      assert Watch.line(event, ag2) =~ ~r/^stop \d+ session_closed by admin reason admin$/

      assert {:error, :session_closed} = Admin.close_session(s)
    end
  end

  describe "revoke_agent/1" do
    test "revoked, not left: the token stops, the claims go back, agent.revoked" do
      %{session: s, ag1: ag1, ag2: ag2, thread: thread} = session_with_claim!()

      assert {:ok, ["T1.1"]} = Admin.revoke_agent(ag2)

      assert %Agent{status: :revoked, left_at: %DateTime{}} = Repo.reload!(ag2)
      assert Threads.state(Repo.reload!(thread)).status == :pending

      [status_changed, revoked] = Events.list_recent(s, 2)
      assert revoked.type == :agent_revoked
      assert revoked.payload == %{"name" => "AG2", "by" => "admin", "released" => ["T1.1"]}
      assert status_changed.type == :thread_status_changed

      assert Watch.line(revoked, ag2) == "stop #{revoked.seq} revoked"
      assert Watch.line(revoked, ag1) == nil
      assert Repo.reload!(Repo.reload!(s)).status == :open

      assert {:error, :not_active} = Admin.revoke_agent(ag2)
    end
  end

  describe "unban/1" do
    test "lifts the bans of the IP and drops it from BanCache" do
      ip = "203.0.113.#{rem(System.unique_integer([:positive]), 250)}"
      ban = Security.ban(ip, :invalid_secret, nil)
      Security.cache_ban(ban)
      assert Security.banned_until(ip)

      Events.subscribe_admin()
      assert {:ok, 1} = Admin.unban(ip)
      assert_receive {:c3_admin, {:unbanned, ^ip}}

      assert %IpBan{lifted_at: %DateTime{}} = Repo.reload!(ban)
      assert BanCache.banned_until(ip, DateTime.utc_now()) == nil
      assert Security.banned_until(ip) == nil
      assert {:ok, 0} = Admin.unban(ip)
    end
  end

  describe "purge_session/1" do
    test "deletes a closed session like the retention does; an open one is refused" do
      %{session: s} = session_with_claim!()
      assert {:error, :not_closed} = Admin.purge_session(s)

      {:ok, _} = Admin.close_session(s)
      Events.subscribe_admin()
      assert :ok = Admin.purge_session(s)
      session_id = s.id
      assert_receive {:c3_admin, {:purged, ^session_id}}

      assert Repo.get(Session, s.id) == nil
      assert Sessions.list_agents(s) == []
      assert Events.list_recent(s, 10) == []
    end
  end

  test "every committed event is also announced on the admin topic" do
    Events.subscribe_admin()
    {:ok, %{session: s}} = Sessions.create_session(%{}, meta())
    session_id = s.id
    assert_receive {:c3_events, ^session_id, 1}
  end

  describe "F8 actions" do
    test "finish: the pending requests are cancelled and the holder's watcher hears it" do
      %{session: session, ag1: ag1, ag2: ag2, thread: thread} = session_with_claim!()

      assert {:ok, %{changed: true, cancelled: ["T1.1"]}} = Admin.finish_thread(thread)
      assert Repo.reload!(thread).finished_at

      [cancelled] = for e <- Events.list_after(session, 0), e.type == :request_cancelled, do: e

      assert %{"cancelled_by" => "admin", "claimed_by" => "AG2", "reason" => "thread finished"} =
               cancelled.payload

      assert cancelled.actor_agent_id == nil
      assert Watch.line(cancelled, ag2) == "cancelled #{cancelled.seq} T1.1 by admin \"Deploy?\""
      assert Watch.line(cancelled, ag1) == nil

      assert {:ok, %{changed: false}} = Admin.finish_thread(thread)
    end

    test "an agent's forced finish also emits request.cancelled, and does not wake itself" do
      %{session: session, ag1: ag1, ag2: ag2, thread: thread} = session_with_claim!()

      {:ok, _} = Threads.finish(ag1, thread, %{"force" => true})
      [cancelled] = for e <- Events.list_after(session, 0), e.type == :request_cancelled, do: e

      assert cancelled.payload["cancelled_by"] == "AG1"
      assert Watch.line(cancelled, ag2) =~ ~r/^cancelled \d+ T1.1 by AG1/
      assert Watch.line(cancelled, ag1) == nil
      assert [%{type: :request_cancelled}] = Sessions.take_notices(ag2)
    end

    test "unlock joins as the admin" do
      %{session: session} = session_with_claim!()
      Repo.update_all(Session, set: [joins_locked_at: DateTime.utc_now()])

      assert {:ok, true} = Admin.unlock_joins(session)
      assert {:ok, false} = Admin.unlock_joins(session)
      refute Repo.reload!(session).joins_locked_at

      [event] = for e <- Events.list_after(session, 0), e.type == :session_joins_unlocked, do: e
      assert event.payload == %{"by" => "admin"}
    end

    test "a request or answer with attachments says files <n> on the watch line" do
      %{session: session, ag1: ag1, ag2: ag2, thread: thread} = session_with_claim!()

      {:ok, _} =
        Threads.post_message(ag2, thread, %{
          "kind" => "response",
          "body" => "Done",
          "attachments" => [
            %{"filename" => "a.log", "text" => "1"},
            %{"filename" => "b.log", "text" => "2"}
          ]
        })

      [posted] = for e <- Events.list_after(session, 0), e.type == :message_posted, do: e

      assert Watch.line(posted, ag1) =~
               ~r/^answer \d+ T1.2 from AG2 resolves T1.1 files 2 "Deploy\?"$/
    end
  end
end
