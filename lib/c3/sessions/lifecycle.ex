defmodule C3.Sessions.Lifecycle do
  @moduledoc """
  The automatic end of a session (spec, *Ciclo de vida y retención*), run by `C3.Sweeper`:

    * `warn_closing/1` — `session.closing_soon` `session_closing_soon` seconds before either
      close, once per reason: for `idle`, once per stretch of inactivity (new activity
      re-arms it); for `max_ttl`, once.
    * `close_expired/1` — closes, as `"system"`, the sessions idle for `session_idle_ttl`
      (`close_reason: idle`) and those past `expires_at` (`max_ttl`, which wins when both
      apply).
    * `purge/1` — deletes the sessions closed more than `retention_days` ago (`0` = at the
      first sweep after the close), in the explicit order of `schema.md` (*Ciclo de vida de
      los datos*).

  The idle close re-checks `last_activity_at` in its `UPDATE`, so a request that lands
  between the scan and the close keeps the session open.
  """
  import Ecto.Query

  alias C3.{Config, Events, Repo, Sessions}
  alias C3.Events.Event
  alias C3.Security.JoinFailure
  alias C3.Sessions.{Agent, IdempotencyKey, Session}
  alias C3.Threads.{Message, Thread}

  @doc "Emits the due `session.closing_soon` warnings. Returns how many."
  def warn_closing(now \\ DateTime.utc_now()) do
    warn = Config.get(:session_closing_soon)
    idle_ttl = Config.get(:session_idle_ttl)
    idle_since = DateTime.add(now, warn - idle_ttl, :second)
    expires_by = DateTime.add(now, warn, :second)

    Session
    |> where([s], s.status == :open)
    |> where([s], s.last_activity_at <= ^idle_since or s.expires_at <= ^expires_by)
    |> Repo.all()
    |> Enum.count(&maybe_warn(&1, idle_ttl, now))
  end

  defp maybe_warn(session, idle_ttl, now) do
    idle_at = DateTime.add(session.last_activity_at, idle_ttl, :second)

    {reason, closes_at} =
      if DateTime.compare(session.expires_at, idle_at) == :gt,
        do: {"idle", idle_at},
        else: {"max_ttl", session.expires_at}

    if DateTime.compare(closes_at, now) == :gt and not warned?(session, reason) do
      {:ok, _} =
        Repo.transaction(fn ->
          Events.append!(session, :session_closing_soon,
            payload: %{reason: reason, closes_at: closes_at}
          )
        end)

      true
    else
      false
    end
  end

  defp warned?(session, reason) do
    Event
    |> where(session_id: ^session.id, type: :session_closing_soon)
    |> select([e], {e.payload, e.inserted_at})
    |> Repo.all()
    |> Enum.any?(fn {payload, at} ->
      payload["reason"] == reason and
        (reason == "max_ttl" or DateTime.compare(at, session.last_activity_at) != :lt)
    end)
  end

  @doc "Closes the sessions past their idle or max TTL. Returns how many."
  def close_expired(now \\ DateTime.utc_now()) do
    idle_cutoff = DateTime.add(now, -Config.get(:session_idle_ttl), :second)

    Session
    |> where([s], s.status == :open)
    |> where([s], s.last_activity_at <= ^idle_cutoff or s.expires_at <= ^now)
    |> select([s], {s.id, s.expires_at})
    |> Repo.all()
    |> Enum.count(fn {id, expires_at} ->
      {reason, still} =
        if DateTime.compare(expires_at, now) == :gt,
          do: {:idle, dynamic([s], s.last_activity_at <= ^idle_cutoff)},
          else: {:max_ttl, dynamic(true)}

      match?(
        {:ok, _},
        Repo.transaction(fn -> Sessions.close_session!(id, reason, nil, now, still) end)
      )
    end)
  end

  @doc "Deletes the sessions whose retention ran out. Returns how many."
  def purge(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -Config.get(:retention_days) * 86_400, :second)

    Session
    |> where([s], s.status == :closed and s.closed_at <= ^cutoff)
    |> select([s], s.id)
    |> Repo.all()
    |> Enum.count(fn id -> match?({:ok, _}, Repo.transaction(fn -> delete_session!(id) end)) end)
  end

  # Children first, by hand: SQLite's cascade order with the cross FKs to `agents` is not
  # to be trusted; the ON DELETE CASCADE stays as a safety net. Attachments join in F8.
  defp delete_session!(session_id) do
    agents = from a in Agent, where: a.session_id == ^session_id, select: a.id

    Repo.delete_all(from k in IdempotencyKey, where: k.agent_id in subquery(agents))
    Repo.delete_all(from e in Event, where: e.session_id == ^session_id)
    Repo.delete_all(from m in Message, where: m.session_id == ^session_id)
    Repo.delete_all(from t in Thread, where: t.session_id == ^session_id)
    Repo.delete_all(from a in Agent, where: a.session_id == ^session_id)

    Repo.update_all(from(f in JoinFailure, where: f.session_id == ^session_id),
      set: [session_id: nil]
    )

    {1, _} = Repo.delete_all(from s in Session, where: s.id == ^session_id)
  end
end
