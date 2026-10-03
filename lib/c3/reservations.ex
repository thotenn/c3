defmodule C3.Reservations do
  @moduledoc """
  Advisory reservations of a session (C3-4): an agent declares it is working on something —
  `repo:c3/lib/**`, `slot:deploy` — so the others do not step on it. C3 never reads the
  pattern beyond the glob (`C3.Reservations.Glob`): it knows nothing about repositories.

  A reservation is active until it is released or `expires_at` passes; an expired one stops
  blocking at once, and `expire/1` (the sweeper) only records it. Two reservations conflict
  when they belong to different agents, overlap, and at least one is exclusive. Asking for
  a conflicting one fails with a `409`, and records the asker among the `waiters` of what
  blocked it, which `reservation.released` / `reservation.expired` name so their watchers wake.

  Every write locks the session row first (an `UPDATE` that changes nothing), so two agents
  reserving at once are serialized on Postgres too. Comparing globs can be slow, and on SQLite
  the lock stops every writer of the node, so `reserve/2` compares against a snapshot before
  taking it, and under the lock only against what was reserved since; the comparisons of one
  call share a budget, over which it is a `422`.

  Errors are `{:error, reason}` with `reason` one of `:reservation_not_found`,
  `{:invalid, message, details}`, `{:forbidden, message}` or `{:conflict, message, details}`.
  """
  import Ecto.Query

  alias C3.{Config, Events, Repo}
  alias C3.Reservations.{Glob, Reservation}
  alias C3.Sessions.{Agent, Session}

  @max_patterns 20
  @max_wildcards 10
  @overlap_budget 200_000
  @max_active 100

  ## Refs

  @doc "The readable id of a reservation, `R<number>`."
  def reservation_ref(%Reservation{number: number}), do: "R#{number}"

  @doc "The number of a reservation ref: `\"R3\"` (any case) → `{:ok, 3}`."
  def parse_reservation_ref(ref) when is_binary(ref) do
    case Regex.run(~r/^[Rr]([1-9][0-9]{0,9})$/, String.trim(ref)) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> :error
    end
  end

  def parse_reservation_ref(_ref), do: :error

  @doc "Whether `reservation` still holds at `now`."
  def active?(%Reservation{released_at: nil, expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def active?(%Reservation{}, _now), do: false

  ## Reads

  @doc """
  The reservations of the agent's session, by number. `params` (strings, as the API gets
  them): `"agent"` — `me` or an agent name; `"status"` — `active` (default) or `all`.
  """
  def list(%Agent{} = me, params \\ %{}) do
    with {:ok, agent_filter} <- agent_param(me, params["agent"]),
         {:ok, active_only?} <- status_param(params["status"]) do
      reservations =
        Reservation
        |> where(session_id: ^me.session_id)
        |> filter_agent(agent_filter)
        |> then(&if active_only?, do: where_active(&1, DateTime.utc_now()), else: &1)
        |> order_by(:number)
        |> preload(:agent)
        |> Repo.all()

      {:ok, reservations}
    end
  end

  ## Writes

  @doc """
  Reserves `attrs["patterns"]` (a list, or one string) for the agent, all or none:
  `"exclusive"` (default `true`), `"ttl_minutes"` (default `C3_RESERVATION_TTL_MINUTES`) and an
  optional `"reason"`. A pattern the agent already holds, with the same exclusivity, is
  renewed instead. Emits `reservation.created` (or `.renewed`) per pattern. Returns
  `{:ok, reservations}`; a conflict is a `409` that names each blocking reservation.
  """
  def reserve(%Agent{} = me, attrs) do
    with {:ok, patterns} <- patterns_param(attrs["patterns"] || attrs["pattern"]),
         {:ok, exclusive?} <- exclusive_param(attrs["exclusive"]),
         {:ok, ttl} <- ttl_param(attrs["ttl_minutes"]),
         {:ok, reason} <- reason_param(attrs["reason"]) do
      snapshot = active(me.session_id, DateTime.utc_now())

      with {:ok, early, budget} <- conflicts(snapshot, me, patterns, exclusive?, @overlap_budget) do
        seen = MapSet.new(snapshot, & &1.id)

        Repo.transaction(fn ->
          now = DateTime.utc_now()
          lock_session!(me.session_id)
          active = active(me.session_id, now)
          by_id = Map.new(active, &{&1.id, &1})
          fresh = Enum.reject(active, &MapSet.member?(seen, &1.id))

          # The snapshot's rows may be stale (waiters, expires_at): use the ones read under the lock.
          early =
            for {pattern, other} <- early,
                Map.has_key?(by_id, other.id),
                do: {pattern, Map.fetch!(by_id, other.id)}

          late =
            case conflicts(fresh, me, patterns, exclusive?, budget) do
              {:ok, late, _budget} -> late
              {:error, error} -> Repo.rollback(error)
            end

          case early ++ late do
            [] ->
              reserve!(me, active, patterns, exclusive?, reason, DateTime.add(now, ttl), now)

            conflicts ->
              {:conflict, add_waiter!(conflicts, me, now)}
          end
        end)
      end
      |> case do
        {:ok, {:conflict, conflicts}} ->
          {:error,
           {:conflict, "Reserved by another agent: #{conflict_summary(conflicts)}",
            %{conflicts: Enum.map(conflicts, &conflict_details/1)}}}

        other ->
          other
      end
    end
  end

  @doc """
  Extends the agent's active reservations `attrs["reservations"]` (`["R1"]`; default: every
  active one of the agent) to `"ttl_minutes"` from now. Emits `reservation.renewed` each.
  """
  def renew(%Agent{} = me, attrs) do
    with {:ok, refs} <- refs_param(attrs["reservations"]),
         {:ok, ttl} <- ttl_param(attrs["ttl_minutes"]) do
      Repo.transaction(fn ->
        now = DateTime.utc_now()
        lock_session!(me.session_id)
        expires_at = DateTime.add(now, ttl)

        for reservation <- mine!(me, refs, now) do
          {1, [renewed]} =
            Reservation
            |> where(id: ^reservation.id)
            |> select([r], r)
            |> Repo.update_all(set: [expires_at: expires_at, updated_at: now])

          Events.append!(%Session{id: me.session_id}, :reservation_renewed,
            actor: me,
            payload: %{
              reservation: reservation_ref(renewed),
              pattern: renewed.pattern,
              agent: me.name,
              expires_at: expires_at
            }
          )

          %{renewed | agent: me}
        end
      end)
    end
  end

  @doc """
  Releases the agent's active reservations `attrs["reservations"]` (default: every active
  one of the agent). Emits `reservation.released` each, with its `waiters`.
  """
  def release(%Agent{} = me, attrs) do
    with {:ok, refs} <- refs_param(attrs["reservations"]) do
      Repo.transaction(fn ->
        now = DateTime.utc_now()
        lock_session!(me.session_id)
        end_all!(mine!(me, refs, now), :released, me, now)
      end)
    end
  end

  @doc """
  Releases every reservation `agent` still holds, for `C3.Sessions.leave/1` and `revoke/1`
  (`reason` `:left` or `:revoked`), with `reservation.released` events for the waiters. Call
  inside a transaction. Returns the refs it released.
  """
  def release_all!(%Agent{} = agent, reason, actor) when reason in [:left, :revoked] do
    now = DateTime.utc_now()

    Reservation
    |> where(agent_id: ^agent.id)
    |> where_active(now)
    |> Repo.all()
    |> Enum.map(&%{&1 | agent: agent})
    |> end_all!(reason, actor, now)
    |> Enum.map(&reservation_ref/1)
  end

  @doc """
  Ends every reservation of a session that is closing, without events: `session.closed`
  already tells every agent. Call inside the transaction of the close.
  """
  def close_session!(session_id, now) do
    Reservation
    |> where([r], r.session_id == ^session_id and is_nil(r.released_at))
    |> Repo.update_all(set: [released_at: now, release_reason: :session_closed, updated_at: now])

    :ok
  end

  @doc """
  Records the reservations of open sessions whose time ran out — `released_at` is their
  `expires_at` — with a `reservation.expired` event each. Run by `C3.Sweeper`; returns how
  many it recorded.
  """
  def expire(now \\ DateTime.utc_now()) do
    due =
      from r in Reservation,
        join: s in Session,
        on: s.id == r.session_id,
        where: s.status == :open and is_nil(r.released_at) and r.expires_at <= ^now

    due
    |> select([r], r.session_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.reduce(0, fn session_id, count ->
      {:ok, expired} =
        Repo.transaction(fn ->
          lock_session!(session_id)

          due
          |> where([r], r.session_id == ^session_id)
          |> Repo.all()
          |> Enum.count(&expire_one!/1)
        end)

      count + expired
    end)
  end

  ## Helpers of the writes

  defp reserve!(me, active, patterns, exclusive?, reason, expires_at, now) do
    mine = Enum.filter(active, &(&1.agent_id == me.id))
    {renewing, new} = Enum.split_with(patterns, &held(mine, &1, exclusive?))

    if length(mine) + length(new) > @max_active do
      Repo.rollback(
        {:invalid, "You would hold more than #{@max_active} active reservations",
         %{patterns: ["too many"]}}
      )
    end

    session = %Session{id: me.session_id}

    Enum.map(patterns, fn pattern ->
      if pattern in renewing do
        reservation = held(mine, pattern, exclusive?)

        {1, [renewed]} =
          Reservation
          |> where(id: ^reservation.id)
          |> select([r], r)
          |> Repo.update_all(set: [expires_at: expires_at, updated_at: now])

        Events.append!(session, :reservation_renewed,
          actor: me,
          payload: %{
            reservation: reservation_ref(renewed),
            pattern: pattern,
            agent: me.name,
            expires_at: expires_at
          }
        )

        %{renewed | agent: me}
      else
        reservation =
          %Reservation{session_id: me.session_id, agent_id: me.id}
          |> Reservation.changeset(%{
            number: next_number!(me.session_id),
            pattern: pattern,
            exclusive: exclusive?,
            reason: reason,
            expires_at: expires_at
          })
          |> Repo.insert()
          |> case do
            {:ok, reservation} -> reservation
            {:error, changeset} -> Repo.rollback(changeset)
          end

        Events.append!(session, :reservation_created,
          actor: me,
          payload: %{
            reservation: reservation_ref(reservation),
            pattern: pattern,
            exclusive: exclusive?,
            agent: me.name,
            expires_at: expires_at
          }
        )

        %{reservation | agent: me}
      end
    end)
  end

  defp held(mine, pattern, exclusive?),
    do: Enum.find(mine, &(&1.pattern == pattern and &1.exclusive == exclusive?))

  defp active(session_id, now) do
    Reservation
    |> where(session_id: ^session_id)
    |> where_active(now)
    |> preload(:agent)
    |> Repo.all()
  end

  # `{:ok, [{requested pattern, blocking reservation}], budget_left}`, in the order of the
  # request, or a `422` when the globs need more than `budget` steps to compare.
  defp conflicts(active, me, patterns, exclusive?, budget) do
    pairs =
      for pattern <- patterns,
          other <- active,
          other.agent_id != me.id,
          exclusive? or other.exclusive,
          do: {pattern, other}

    Enum.reduce_while(pairs, {:ok, [], budget}, fn {pattern, other} = pair, {:ok, acc, budget} ->
      case Glob.overlap(pattern, other.pattern, budget) do
        {:ok, true, budget} -> {:cont, {:ok, [pair | acc], budget}}
        {:ok, false, budget} -> {:cont, {:ok, acc, budget}}
        :too_complex -> {:halt, :too_complex}
      end
    end)
    |> case do
      {:ok, found, budget} ->
        {:ok, Enum.reverse(found), budget}

      :too_complex ->
        invalid(:patterns, "These patterns are too complex to compare; use fewer wildcards")
    end
  end

  # Commits the asker among the waiters of what blocked it: the caller turns the result into
  # the `409` after the transaction, instead of rolling it back.
  defp add_waiter!(conflicts, me, now) do
    for {_pattern, other} <- conflicts, uniq: true do
      other
    end
    |> Enum.reject(&(me.name in &1.waiters))
    |> Enum.each(fn other ->
      Reservation
      |> where(id: ^other.id)
      |> Repo.update_all(set: [waiters: other.waiters ++ [me.name], updated_at: now])
    end)

    conflicts
  end

  defp end_all!(reservations, reason, actor, now) do
    Enum.map(reservations, fn reservation ->
      {1, [ended]} =
        Reservation
        |> where(id: ^reservation.id)
        |> select([r], r)
        |> Repo.update_all(set: [released_at: now, release_reason: reason, updated_at: now])

      Events.append!(%Session{id: reservation.session_id}, :reservation_released,
        actor: actor,
        payload: %{
          reservation: reservation_ref(ended),
          pattern: ended.pattern,
          agent: reservation.agent.name,
          reason: reason,
          waiters: ended.waiters
        }
      )

      %{ended | agent: reservation.agent}
    end)
  end

  # The update is conditional: a reservation released in the meantime is left alone.
  defp expire_one!(reservation) do
    {count, ended} =
      Reservation
      |> where([r], r.id == ^reservation.id and is_nil(r.released_at))
      |> select([r], r)
      |> Repo.update_all(
        set: [
          released_at: reservation.expires_at,
          release_reason: :expired,
          updated_at: DateTime.utc_now()
        ]
      )

    with 1 <- count,
         [ended] <- ended do
      agent = Repo.get!(Agent, ended.agent_id)

      Events.append!(%Session{id: ended.session_id}, :reservation_expired,
        payload: %{
          reservation: reservation_ref(ended),
          pattern: ended.pattern,
          agent: agent.name,
          waiters: ended.waiters
        }
      )

      true
    else
      _ -> false
    end
  end

  # The agent's active reservations among `refs` (nil = all of them). A ref that is not in
  # the session is a `404`, another agent's a `403`, one that already ended a `409`.
  defp mine!(me, nil, now) do
    Reservation
    |> where(agent_id: ^me.id)
    |> where_active(now)
    |> order_by(:number)
    |> Repo.all()
    |> Enum.map(&%{&1 | agent: me})
  end

  defp mine!(me, numbers, now) do
    found =
      Reservation
      |> where([r], r.session_id == ^me.session_id and r.number in ^numbers)
      |> preload(:agent)
      |> Repo.all()
      |> Map.new(&{&1.number, &1})

    for number <- numbers do
      reservation = Map.get(found, number) || Repo.rollback(:reservation_not_found)
      ref = reservation_ref(reservation)

      cond do
        reservation.agent_id != me.id ->
          Repo.rollback({:forbidden, "#{ref} is held by #{reservation.agent.name}, not you"})

        not active?(reservation, now) ->
          Repo.rollback(
            {:conflict, "#{ref} is no longer active",
             %{reservation: ref, released_at: reservation.released_at || reservation.expires_at}}
          )

        true ->
          reservation
      end
    end
  end

  defp lock_session!(session_id) do
    {1, _} =
      Session
      |> where(id: ^session_id)
      |> Repo.update_all(inc: [next_reservation_number: 0])
  end

  defp next_number!(session_id) do
    {1, [next]} =
      Session
      |> where(id: ^session_id)
      |> select([s], s.next_reservation_number)
      |> Repo.update_all(inc: [next_reservation_number: 1])

    next - 1
  end

  defp where_active(query, now),
    do: where(query, [r], is_nil(r.released_at) and r.expires_at > ^now)

  defp conflict_summary(conflicts) do
    conflicts
    |> Enum.map(fn {_pattern, other} -> "#{reservation_ref(other)} (#{other.agent.name})" end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp conflict_details({pattern, other}) do
    %{
      pattern: pattern,
      reservation: reservation_ref(other),
      holder: other.agent.name,
      held_pattern: other.pattern,
      exclusive: other.exclusive,
      expires_at: other.expires_at
    }
  end

  ## Params

  defp patterns_param(pattern) when is_binary(pattern), do: patterns_param([pattern])

  defp patterns_param(patterns) when is_list(patterns) and patterns != [] do
    cond do
      length(patterns) > @max_patterns ->
        invalid(:patterns, "at most #{@max_patterns} patterns per call")

      not Enum.all?(patterns, &valid_pattern?/1) ->
        invalid(
          :patterns,
          "each pattern must be <namespace>:<glob> (repo:c3/lib/**, slot:deploy), " <>
            "up to 256 bytes, without spaces"
        )

      Enum.any?(patterns, &(Glob.wildcards(&1) > @max_wildcards)) ->
        invalid(:patterns, "a pattern takes at most #{@max_wildcards} wildcards (?, *, **)")

      true ->
        {:ok, Enum.uniq(patterns)}
    end
  end

  defp patterns_param(_patterns), do: invalid(:patterns, "patterns must be a list of strings")

  defp valid_pattern?(pattern) do
    is_binary(pattern) and byte_size(pattern) <= 256 and pattern =~ Reservation.pattern_format()
  end

  defp exclusive_param(nil), do: {:ok, true}
  defp exclusive_param(value) when is_boolean(value), do: {:ok, value}
  defp exclusive_param("true"), do: {:ok, true}
  defp exclusive_param("false"), do: {:ok, false}
  defp exclusive_param(_value), do: invalid(:exclusive, "exclusive must be a boolean")

  defp ttl_param(nil), do: {:ok, Config.get(:reservation_ttl)}

  defp ttl_param(minutes) when is_integer(minutes) and minutes > 0 do
    max = Config.get(:reservation_max_ttl)

    if minutes * 60 <= max,
      do: {:ok, minutes * 60},
      else: invalid(:ttl_minutes, "ttl_minutes must be at most #{div(max, 60)}")
  end

  defp ttl_param(minutes) when is_binary(minutes) do
    case Integer.parse(minutes) do
      {n, ""} -> ttl_param(n)
      _ -> ttl_param(0)
    end
  end

  defp ttl_param(_minutes), do: invalid(:ttl_minutes, "ttl_minutes must be a positive integer")

  defp reason_param(nil), do: {:ok, nil}

  defp reason_param(reason) when is_binary(reason) and byte_size(reason) <= 500,
    do: {:ok, reason}

  defp reason_param(_reason), do: invalid(:reason, "reason must be a string of up to 500 bytes")

  defp refs_param(nil), do: {:ok, nil}

  defp refs_param(refs) when is_list(refs) and refs != [] do
    refs
    |> Enum.map(&parse_reservation_ref/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, n}, {:ok, acc} -> {:cont, {:ok, [n | acc]}}
      :error, _acc -> {:halt, :error}
    end)
    |> case do
      {:ok, numbers} -> {:ok, numbers |> Enum.reverse() |> Enum.uniq()}
      :error -> invalid(:reservations, "reservations must be ids like R3")
    end
  end

  defp refs_param(_refs), do: invalid(:reservations, "reservations must be a list of ids like R3")

  defp agent_param(_me, nil), do: {:ok, nil}
  defp agent_param(me, "me"), do: {:ok, {:id, me.id}}

  defp agent_param(_me, name) when is_binary(name) do
    if name =~ ~r/^AG[1-9][0-9]{0,9}$/,
      do: {:ok, {:name, name}},
      else: invalid(:agent, "agent must be me or an agent name like AG2")
  end

  defp agent_param(_me, _name), do: invalid(:agent, "agent must be me or an agent name like AG2")

  defp status_param(nil), do: {:ok, true}
  defp status_param("active"), do: {:ok, true}
  defp status_param("all"), do: {:ok, false}
  defp status_param(_status), do: invalid(:status, "status must be active or all")

  defp filter_agent(query, nil), do: query
  defp filter_agent(query, {:id, id}), do: where(query, agent_id: ^id)

  defp filter_agent(query, {:name, name}) do
    query
    |> join(:inner, [r], a in assoc(r, :agent))
    |> where([r, a], a.name == ^name)
  end

  defp invalid(field, message), do: {:error, {:invalid, message, %{field => [message]}}}
end
