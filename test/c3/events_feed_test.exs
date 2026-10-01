defmodule C3.EventsFeedTest do
  use C3.DataCase

  import C3.Fixtures

  alias C3.Events

  setup do
    %{session: session_fixture()}
  end

  defp append(session, type \\ :agent_joined) do
    {:ok, event} = Repo.transaction(fn -> Events.append!(session, type) end)
    event
  end

  # Commits an event from another process after `delay_ms`.
  defp append_later(session, delay_ms) do
    Task.async(fn ->
      Process.sleep(delay_ms)
      append(session)
    end)
  end

  defp elapsed_ms(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  describe "fan-out" do
    test "an event is announced after its transaction commits, not before", %{session: s} do
      Events.subscribe(s)
      id = s.id

      Repo.transaction(fn ->
        Events.append!(s, :agent_joined)
        Events.append!(s, :thread_opened)
        refute_received {:c3_events, _, _}
      end)

      assert_received {:c3_events, ^id, 2}
      refute_received {:c3_events, _, _}, "one announcement per transaction, with the top seq"
    end

    test "a rollback announces nothing", %{session: s} do
      Events.subscribe(s)

      assert {:error, :nope} =
               Repo.transaction(fn ->
                 Events.append!(s, :agent_joined)
                 Repo.rollback(:nope)
               end)

      refute_received {:c3_events, _, _}
      assert Events.list_after(s, 0) == []
    end

    test "a raise announces nothing and leaves no pending state behind", %{session: s} do
      Events.subscribe(s)

      assert_raise RuntimeError, fn ->
        Repo.transaction(fn ->
          Events.append!(s, :agent_joined)
          raise "boom"
        end)
      end

      refute_received {:c3_events, _, _}
      assert append(s).seq == 1
      assert_received {:c3_events, _, 1}
    end

    test "a nested transaction announces only when the outermost one commits", %{session: s} do
      Events.subscribe(s)

      Repo.transaction(fn ->
        {:ok, _} = Repo.transaction(fn -> Events.append!(s, :agent_joined) end)
        refute_received {:c3_events, _, _}
      end)

      assert_received {:c3_events, _, 1}
    end

    test "outside a transaction the event is announced at once", %{session: s} do
      Events.subscribe(s)
      Events.append!(s, :agent_joined)
      assert_received {:c3_events, _, 1}
    end

    test "only the session's own subscribers hear it", %{session: s} do
      other = session_fixture()
      Events.subscribe(other)
      append(s)
      refute_received {:c3_events, _, _}
    end
  end

  describe "wait_after/4 (long-poll)" do
    test "returns the pending events at once", %{session: s} do
      append(s)
      append(s)
      {ms, events} = elapsed_ms(fn -> Events.wait_after(s, 0, 5_000) end)
      assert Enum.map(events, & &1.seq) == [1, 2]
      assert ms < 1_000
    end

    test "waits the whole timeout and returns [] when nothing comes", %{session: s} do
      {ms, events} = elapsed_ms(fn -> Events.wait_after(s, 0, 200) end)
      assert events == []
      assert ms >= 200
    end

    test "wakes up as soon as an event is committed", %{session: s} do
      task = append_later(s, 100)
      {ms, events} = elapsed_ms(fn -> Events.wait_after(s, 0, 5_000) end)
      Task.await(task)

      assert [%{seq: 1}] = events
      assert ms >= 100 and ms < 2_000
    end

    test "ignores the announcements of events at or before the cursor", %{session: s} do
      append(s)
      task = append_later(s, 100)
      assert [%{seq: 2}] = Events.wait_after(s, 1, 5_000)
      Task.await(task)
    end

    test "an event committed between the subscription and the query is not lost", %{session: s} do
      # Committed and announced right after subscribing, before the query runs: the query
      # finds it, so no wait.
      {ms, events} =
        elapsed_ms(fn -> Events.wait_after(s, 0, 5_000, subscribed: fn -> append(s) end) end)

      assert [%{seq: 1}] = events
      assert ms < 1_000
    end

    test "an event committed between two polls is in the next one", %{session: s} do
      append(s)
      [first] = Events.wait_after(s, 0, 1_000)
      append(s)
      assert [%{seq: 2}] = Events.wait_after(s, first.seq, 1_000)
    end

    test "respects :limit", %{session: s} do
      for _ <- 1..3, do: append(s)
      assert Enum.map(Events.wait_after(s, 0, 1_000, limit: 2), & &1.seq) == [1, 2]
    end

    test "leaves no subscription nor announcement behind", %{session: s} do
      Events.wait_after(s, 0, 10)
      append(s)
      refute_received {:c3_events, _, _}
    end
  end
end
