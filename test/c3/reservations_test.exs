defmodule C3.ReservationsTest do
  use C3.DataCase

  import C3.Fixtures

  alias C3.Events.Event
  alias C3.Reservations
  alias C3.Reservations.Reservation
  alias C3.Sessions

  setup do
    session = session_fixture()
    ag1 = agent_fixture(session, %{number: 1})
    ag2 = agent_fixture(session, %{number: 2})
    %{session: session, ag1: ag1, ag2: ag2}
  end

  defp reserve(agent, patterns, attrs \\ %{}),
    do: Reservations.reserve(agent, Map.put(attrs, "patterns", patterns))

  defp ids({:ok, reservations}), do: Enum.map(reservations, &Reservations.reservation_ref/1)

  defp events(session) do
    Event
    |> where(session_id: ^session.id)
    |> order_by(:seq)
    |> Repo.all()
    |> Enum.map(&{&1.type, &1.payload})
  end

  defp get(session, number), do: Repo.get_by!(Reservation, session_id: session.id, number: number)

  # Moves a reservation's end to the past, as if its time had run out.
  defp run_out!(reservation) do
    past = DateTime.add(DateTime.utc_now(), -60)
    Repo.update_all(where(Reservation, id: ^reservation.id), set: [expires_at: past])
  end

  describe "reserve/2" do
    test "numbers reservations per session and emits reservation.created", ctx do
      assert ["R1", "R2"] = ids(reserve(ctx.ag1, ["repo:c3/lib/**", "slot:deploy"]))

      r1 = get(ctx.session, 1)
      assert %{exclusive: true, agent_id: agent_id, waiters: []} = r1
      assert agent_id == ctx.ag1.id
      assert DateTime.diff(r1.expires_at, DateTime.utc_now()) in 3590..3600

      assert [
               {:reservation_created,
                %{"reservation" => "R1", "pattern" => "repo:c3/lib/**", "agent" => "AG1"}},
               {:reservation_created, %{"reservation" => "R2", "exclusive" => true}}
             ] = events(ctx.session)
    end

    test "an overlapping exclusive reservation of another agent is a conflict, all or none",
         ctx do
      {:ok, _} = reserve(ctx.ag1, ["repo:c3/lib/**"])

      assert {:error, {:conflict, message, %{conflicts: [conflict]}}} =
               reserve(ctx.ag2, ["slot:deploy", "repo:c3/lib/c3.ex"])

      assert message =~ "R1 (AG1)"

      assert %{
               pattern: "repo:c3/lib/c3.ex",
               reservation: "R1",
               holder: "AG1",
               held_pattern: "repo:c3/lib/**",
               exclusive: true
             } = conflict

      assert Repo.aggregate(Reservation, :count) == 1, "the free pattern was not reserved"
      assert get(ctx.session, 1).waiters == ["AG2"], "the waiter survived the 409"

      {:error, _} = reserve(ctx.ag2, ["repo:c3/lib/**"])
      assert get(ctx.session, 1).waiters == ["AG2"], "a waiter is listed once"
    end

    test "shared reservations conflict only with exclusive ones", ctx do
      {:ok, _} = reserve(ctx.ag1, ["repo:c3/docs/**"], %{"exclusive" => false})
      assert {:ok, _} = reserve(ctx.ag2, ["repo:c3/docs/api.md"], %{"exclusive" => false})
      assert {:error, {:conflict, _, _}} = reserve(ctx.ag2, ["repo:c3/docs/mcp.md"])
    end

    test "my own reservations never conflict with mine; the same pattern is renewed", ctx do
      {:ok, [r1]} = reserve(ctx.ag1, ["repo:c3/lib/**"], %{"ttl_minutes" => 5})
      assert ["R2"] = ids(reserve(ctx.ag1, ["repo:c3/lib/c3.ex"]))
      assert ["R1"] = ids(reserve(ctx.ag1, ["repo:c3/lib/**"], %{"ttl_minutes" => 30}))

      assert DateTime.compare(get(ctx.session, 1).expires_at, r1.expires_at) == :gt
      assert {:reservation_renewed, %{"reservation" => "R1"}} = List.last(events(ctx.session))
    end

    test "an expired reservation no longer blocks, before the sweeper records it", ctx do
      {:ok, [r1]} = reserve(ctx.ag1, ["slot:deploy"])
      run_out!(r1)
      assert ["R2"] = ids(reserve(ctx.ag2, ["slot:deploy"]))
    end

    test "checks its arguments", ctx do
      for {attrs, field} <- [
            {%{"patterns" => []}, :patterns},
            {%{"patterns" => ["no namespace"]}, :patterns},
            {%{"patterns" => ["src/**"]}, :patterns},
            {%{"patterns" => [String.duplicate("a", 300) <> ":x"]}, :patterns},
            {%{"patterns" => Enum.map(1..21, &"slot:s#{&1}")}, :patterns},
            {%{"patterns" => ["slot:a"], "exclusive" => "maybe"}, :exclusive},
            {%{"patterns" => ["slot:a"], "ttl_minutes" => 0}, :ttl_minutes},
            {%{"patterns" => ["slot:a"], "ttl_minutes" => 24 * 60 + 1}, :ttl_minutes},
            {%{"patterns" => ["slot:a"], "reason" => 7}, :reason}
          ] do
        assert {:error, {:invalid, _, %{^field => _}}} = Reservations.reserve(ctx.ag1, attrs),
               "#{inspect(attrs)} should fail on #{field}"
      end

      assert {:ok, [_]} = Reservations.reserve(ctx.ag1, %{"pattern" => "slot:one"})
    end
  end

  describe "the cost of comparing globs" do
    test "a pattern takes at most 10 wildcards", ctx do
      assert {:ok, [_]} = reserve(ctx.ag1, ["repo:x/" <> String.duplicate("*/", 10) <> "a"])

      assert {:error, {:invalid, message, %{patterns: _}}} =
               reserve(ctx.ag1, ["repo:x/" <> String.duplicate("?", 11)])

      assert message =~ "10 wildcards"
    end

    test "patterns too costly to compare are a 422, quickly, and reserve nothing", ctx do
      pad = String.duplicate("a", 200)
      held = for n <- 1..5, do: "repo:x/*#{n}" <> pad <> String.duplicate("*a", 9)
      {:ok, _} = reserve(ctx.ag1, held)

      asked = for n <- 1..20, do: "repo:x/" <> String.duplicate("a*", 9) <> pad <> "#{n}*b"
      {micros, result} = :timer.tc(fn -> reserve(ctx.ag2, asked) end)

      assert {:error, {:invalid, message, %{patterns: _}}} = result
      assert message =~ "too complex"
      assert micros < 2_000_000
      assert Repo.aggregate(where(Reservation, agent_id: ^ctx.ag2.id), :count) == 0
    end
  end

  describe "renew/2 and release/2" do
    setup ctx do
      {:ok, _} = reserve(ctx.ag1, ["repo:c3/lib/**", "slot:deploy"])
      {:ok, _} = reserve(ctx.ag2, ["slot:build"])
      :ok
    end

    test "renew extends the given reservations, or all of mine", ctx do
      assert ["R1"] = ids(Reservations.renew(ctx.ag1, %{"reservations" => ["r1"]}))
      assert ["R1", "R2"] = ids(Reservations.renew(ctx.ag1, %{"ttl_minutes" => 120}))
      assert DateTime.diff(get(ctx.session, 2).expires_at, DateTime.utc_now()) in 7190..7200
    end

    test "release ends them with reservation.released and their waiters", ctx do
      {:error, _} = reserve(ctx.ag2, ["slot:deploy"])
      assert ["R2"] = ids(Reservations.release(ctx.ag1, %{"reservations" => ["R2"]}))

      assert %{released_at: %DateTime{}, release_reason: :released} = get(ctx.session, 2)

      assert {:reservation_released,
              %{
                "reservation" => "R2",
                "pattern" => "slot:deploy",
                "agent" => "AG1",
                "reason" => "released",
                "waiters" => ["AG2"]
              }} = List.last(events(ctx.session))

      assert ["R1"] = ids(Reservations.release(ctx.ag1, %{}))
      assert {:ok, []} = Reservations.release(ctx.ag1, %{})
      assert ["R4"] = ids(reserve(ctx.ag2, ["slot:deploy"]))
    end

    test "only the holder renews or releases; unknown and ended ones fail", ctx do
      assert {:error, {:forbidden, _}} =
               Reservations.release(ctx.ag2, %{"reservations" => ["R1"]})

      assert {:error, {:forbidden, _}} = Reservations.renew(ctx.ag2, %{"reservations" => ["R1"]})

      assert {:error, :reservation_not_found} =
               Reservations.renew(ctx.ag1, %{"reservations" => ["R9"]})

      assert {:error, {:invalid, _, _}} =
               Reservations.release(ctx.ag1, %{"reservations" => ["K1"]})

      {:ok, _} = Reservations.release(ctx.ag1, %{"reservations" => ["R1"]})

      assert {:error, {:conflict, _, %{reservation: "R1"}}} =
               Reservations.renew(ctx.ag1, %{"reservations" => ["R1"]})

      assert get(ctx.session, 2).released_at == nil, "a failed call changed nothing"
    end
  end

  describe "list/2" do
    test "the active reservations by default, of an agent or all of them", ctx do
      {:ok, _} = reserve(ctx.ag1, ["slot:a", "slot:b"])
      {:ok, _} = reserve(ctx.ag2, ["slot:c"])
      {:ok, _} = Reservations.release(ctx.ag1, %{"reservations" => ["R1"]})

      assert ["R2", "R3"] = ids(Reservations.list(ctx.ag1))
      assert ["R2"] = ids(Reservations.list(ctx.ag2, %{"agent" => "AG1"}))
      assert ["R3"] = ids(Reservations.list(ctx.ag2, %{"agent" => "me"}))

      assert ["R1", "R2"] =
               ids(Reservations.list(ctx.ag2, %{"agent" => "AG1", "status" => "all"}))

      assert {:error, {:invalid, _, _}} = Reservations.list(ctx.ag1, %{"status" => "gone"})
      assert {:error, {:invalid, _, _}} = Reservations.list(ctx.ag1, %{"agent" => "bob"})
    end

    test "only the agent's session", ctx do
      other = agent_fixture(session_fixture(), %{number: 1})
      {:ok, _} = reserve(other, ["slot:a"])
      assert {:ok, []} = Reservations.list(ctx.ag1)
      assert ["R1"] = ids(reserve(ctx.ag1, ["slot:a"]))
    end
  end

  describe "expire/1" do
    test "records the reservations whose time ran out, once, with their waiters", ctx do
      {:ok, [r1, _r2]} = reserve(ctx.ag1, ["slot:a", "slot:b"])
      {:error, _} = reserve(ctx.ag2, ["slot:a"])
      run_out!(r1)

      assert Reservations.expire() == 1
      assert Reservations.expire() == 0

      assert %{release_reason: :expired, released_at: released_at} = get(ctx.session, 1)
      assert DateTime.compare(released_at, DateTime.utc_now()) == :lt

      assert {:reservation_expired,
              %{"reservation" => "R1", "agent" => "AG1", "waiters" => ["AG2"]}} =
               List.last(events(ctx.session))

      assert get(ctx.session, 2).released_at == nil
    end
  end

  describe "an agent that goes" do
    test "leaving releases its reservations, for its waiters", ctx do
      {:ok, _} = reserve(ctx.ag1, ["slot:a"])
      {:error, _} = reserve(ctx.ag2, ["slot:a"])
      {:ok, _} = Sessions.leave(ctx.ag1)

      assert %{release_reason: :left} = get(ctx.session, 1)

      assert [{:reservation_released, %{"reason" => "left", "waiters" => ["AG2"]}}, _left] =
               ctx.session |> events() |> Enum.take(-2)

      assert ["R2"] = ids(reserve(ctx.ag2, ["slot:a"]))
    end

    test "being revoked releases them too", ctx do
      {:ok, _} = reserve(ctx.ag1, ["slot:a"])
      {:ok, _} = Sessions.revoke(ctx.ag1)
      assert %{release_reason: :revoked} = get(ctx.session, 1)
    end

    test "closing the session ends every reservation, without events", ctx do
      {:ok, _} = reserve(ctx.ag1, ["slot:a"])
      {:ok, _} = reserve(ctx.ag2, ["slot:b"])
      before = length(events(ctx.session))
      {:ok, _} = Sessions.close(ctx.ag1)

      assert %{release_reason: :session_closed} = get(ctx.session, 1)
      assert %{release_reason: :session_closed} = get(ctx.session, 2)
      assert [{:session_closed, _}] = ctx.session |> events() |> Enum.drop(before)
      assert Reservations.expire() == 0
    end
  end
end
