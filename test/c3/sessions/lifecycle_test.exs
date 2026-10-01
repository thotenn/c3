defmodule C3.Sessions.LifecycleTest do
  use C3.DataCase

  import C3.Fixtures

  alias C3.Events.Event
  alias C3.Security
  alias C3.Security.{IpBan, JoinFailure}
  alias C3.Sessions
  alias C3.Sessions.{Agent, IdempotencyKey, Lifecycle, Session}
  alias C3.Threads.{Message, Thread}

  @hour 3600
  @day 86_400

  setup do
    %{now: DateTime.utc_now()}
  end

  defp ago(now, seconds), do: DateTime.add(now, -seconds, :second)
  defp ahead(now, seconds), do: DateTime.add(now, seconds, :second)

  defp open_session(now, attrs) do
    session_fixture(Enum.into(attrs, %{last_activity_at: now, expires_at: ahead(now, 6 * @day)}))
  end

  defp closed_session(closed_at) do
    session_fixture(%{
      status: :closed,
      closed_at: closed_at,
      closed_by: "system",
      close_reason: :idle
    })
  end

  defp warnings(session) do
    Event
    |> where(session_id: ^session.id, type: :session_closing_soon)
    |> order_by(:seq)
    |> Repo.all()
  end

  defp put_config(key, value) do
    previous = Application.get_env(:c3, key)
    Application.put_env(:c3, key, value)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:c3, key),
        else: Application.put_env(:c3, key, previous)
    end)
  end

  describe "warn_closing/1" do
    test "warns an idle session once, an hour before its idle close", %{now: now} do
      due = open_session(now, last_activity_at: ago(now, 23 * @hour + 30 * 60))
      not_due = open_session(now, last_activity_at: ago(now, 22 * @hour))

      assert Lifecycle.warn_closing(now) == 1
      assert [%Event{payload: %{"reason" => "idle", "closes_at" => closes_at}}] = warnings(due)
      assert closes_at == DateTime.to_iso8601(ahead(due.last_activity_at, 24 * @hour))
      assert warnings(not_due) == []

      assert Lifecycle.warn_closing(ahead(now, 60)) == 0
    end

    test "new activity re-arms the idle warning", %{now: now} do
      s = open_session(now, last_activity_at: ago(now, 23 * @hour + 30 * 60))
      assert Lifecycle.warn_closing(now) == 1

      # Active again a minute later, then silent until the next warning is due.
      later = ahead(now, 60)
      Sessions.touch_activity(Repo.reload!(s), later)
      assert Lifecycle.warn_closing(ahead(later, 23 * @hour + 30 * 60)) == 1
      assert length(warnings(s)) == 2
    end

    test "warns once before max_ttl, whatever the activity", %{now: now} do
      s = open_session(now, expires_at: ahead(now, 30 * 60))

      assert Lifecycle.warn_closing(now) == 1
      assert [%{payload: %{"reason" => "max_ttl"}}] = warnings(s)

      Sessions.touch_activity(Repo.reload!(s), ahead(now, 120))
      assert Lifecycle.warn_closing(ahead(now, 180)) == 0
    end

    test "does not warn a session already due nor a closed one", %{now: now} do
      open_session(now, last_activity_at: ago(now, 25 * @hour))
      closed_session(ago(now, @hour))
      assert Lifecycle.warn_closing(now) == 0
    end

    test "honors session_closing_soon", %{now: now} do
      put_config(:session_closing_soon, 2 * @hour)
      open_session(now, last_activity_at: ago(now, 22 * @hour + 30 * 60))
      assert Lifecycle.warn_closing(now) == 1
    end
  end

  describe "close_expired/1" do
    test "closes an idle session as system, revoking its tokens", %{now: now} do
      s = open_session(now, last_activity_at: ago(now, 24 * @hour + 1))
      agent = agent_fixture(s)
      active = open_session(now, last_activity_at: ago(now, 23 * @hour))

      assert Lifecycle.close_expired(now) == 1

      assert %Session{status: :closed, close_reason: :idle, closed_by: "system"} =
               Repo.reload!(s)

      assert Repo.reload!(agent).status == :revoked
      assert Repo.reload!(active).status == :open

      assert [%Event{type: :session_closed, actor_agent_id: nil, payload: payload}] =
               Repo.all(from e in Event, where: e.session_id == ^s.id)

      assert payload == %{"closed_by" => "system", "reason" => "idle"}
    end

    test "max_ttl wins when both apply", %{now: now} do
      s = open_session(now, last_activity_at: ago(now, 30 * @hour), expires_at: ago(now, 1))
      assert Lifecycle.close_expired(now) == 1
      assert Repo.reload!(s).close_reason == :max_ttl
    end

    test "an active session past expires_at is closed too", %{now: now} do
      s = open_session(now, expires_at: now)
      assert Lifecycle.close_expired(now) == 1
      assert Repo.reload!(s).close_reason == :max_ttl
    end

    test "honors session_idle_ttl", %{now: now} do
      put_config(:session_idle_ttl, @hour)
      s = open_session(now, last_activity_at: ago(now, @hour))
      assert Lifecycle.close_expired(now) == 1
      assert Repo.reload!(s).close_reason == :idle
    end

    test "the close re-checks its condition on the row", %{now: now} do
      s = open_session(now, [])

      assert {:error, :session_closed} =
               Repo.transaction(fn ->
                 Sessions.close_session!(s.id, :idle, nil, now, dynamic(false))
               end)

      assert Repo.reload!(s).status == :open
    end
  end

  describe "purge/1" do
    defp populated(closed_at) do
      s = closed_session(closed_at)
      a1 = agent_fixture(s)
      a2 = agent_fixture(s)
      thread = thread_fixture(a1)
      request = request_fixture(thread, a1, a2)
      reply = note_fixture(thread, a2, %{reply_to_message_id: request.id})

      %Event{session_id: s.id, actor_agent_id: a2.id, thread_id: thread.id, message_id: reply.id}
      |> Event.changeset(%{seq: 1, type: :message_posted})
      |> Repo.insert!()

      idempotency_key_fixture(a1)
      failure = join_failure_fixture(s)
      %{session: s, failure: failure}
    end

    defp count(schema, session_id) do
      Repo.aggregate(from(r in schema, where: r.session_id == ^session_id), :count)
    end

    test "deletes a session past its retention, with everything in it", %{now: now} do
      %{session: old, failure: failure} = populated(ago(now, 30 * @day + 1))
      %{session: kept} = populated(ago(now, 29 * @day))
      ban = ip_ban_fixture()

      assert Lifecycle.purge(now) == 1

      refute Repo.get(Session, old.id)

      for schema <- [Agent, Thread, Message, Event],
          do: assert(count(schema, old.id) == 0)

      assert Repo.aggregate(IdempotencyKey, :count) == 1
      assert Repo.reload!(failure).session_id == nil
      assert Repo.reload!(ban)
      assert Repo.get(Session, kept.id)
      assert count(Agent, kept.id) == 2
    end

    test "never touches an open session", %{now: now} do
      s = open_session(now, [])
      assert Lifecycle.purge(ahead(now, 400 * @day)) == 0
      assert Repo.get(Session, s.id)
    end

    test "retention_days 0 purges at the first sweep after the close", %{now: now} do
      put_config(:retention_days, 0)
      %{session: s} = populated(now)
      assert Lifecycle.purge(now) == 1
      refute Repo.get(Session, s.id)
    end
  end

  test "Security.purge_history/1 drops what is older than 30 days", %{now: now} do
    old = join_failure_fixture(nil)

    Repo.update_all(from(f in JoinFailure, where: f.id == ^old.id),
      set: [inserted_at: ago(now, 31 * @day)]
    )

    recent = join_failure_fixture(nil)
    expired = ip_ban_fixture(%{banned_until: ago(now, 31 * @day)})
    lifted = ip_ban_fixture(%{banned_until: ahead(now, @hour), lifted_at: ago(now, 31 * @day)})
    current = ip_ban_fixture()

    assert Security.purge_history(now) == %{join_failures: 1, ip_bans: 2}
    refute Repo.get(JoinFailure, old.id)
    assert Repo.get(JoinFailure, recent.id)
    refute Repo.get(IpBan, expired.id)
    refute Repo.get(IpBan, lifted.id)
    assert Repo.get(IpBan, current.id)
  end

  test "the sweeper runs every job", %{now: now} do
    assert %{
             claims_expired: 0,
             sessions_warned: 0,
             sessions_closed: 0,
             sessions_purged: 0,
             idempotency_keys_purged: 0,
             security_purged: %{join_failures: 0, ip_bans: 0}
           } = C3.Sweeper.run(now)
  end
end
