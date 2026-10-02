defmodule C3.Admin do
  @moduledoc """
  What the admin pages read and do (spec, *Admin y UI*). There are no users in v1: whoever
  has `C3_ADMIN_TOKEN` is the admin, and with it unset there is no admin at all.

  The actions reuse the domain, so each one leaves the same trace as its automatic twin:

    * `close_session/1` — `C3.Sessions.close_session!/5` as `"admin"` (`close_reason:
      admin`): every token revoked, `session.closed`, the watchers get `stop`.
    * `revoke_agent/1` — `C3.Sessions.revoke/1`: like a leave, but `revoked` and
      `agent.revoked`; the agent's watcher gets `stop revoked`.
    * `unban/1` — `C3.Security.unban/1`: `lifted_at` and out of `BanCache`. No session
      event (a ban is per IP), only `{:c3_admin, {:unbanned, ip}}`.
    * `purge_session/1` — `C3.Sessions.Lifecycle.purge_session/1`, the retention's delete,
      for a closed session. Nothing is left to hold an event: `{:c3_admin, {:purged, id}}`.
  """
  import Ecto.Query

  alias C3.{Config, Events, Repo, Security, Sessions, Threads}
  alias C3.Sessions.{Agent, Lifecycle, Session}
  alias C3.Threads.Thread

  ## Access

  @doc "Whether the admin is enabled (`C3_ADMIN_TOKEN` is set)."
  def enabled?, do: is_binary(Config.get(:admin_token))

  @doc "Whether `token` is the admin token. Always `false` with the admin disabled."
  def valid_token?(token) when is_binary(token) do
    case Config.get(:admin_token) do
      admin when is_binary(admin) -> Plug.Crypto.secure_compare(token, admin)
      nil -> false
    end
  end

  def valid_token?(_token), do: false

  @doc """
  A fingerprint of the current admin token, what a login stores in the session cookie
  instead of the token: rotating the token voids every login. `nil` with the admin disabled.
  """
  def fingerprint do
    if token = Config.get(:admin_token) do
      :crypto.mac(:hmac, :sha256, "c3 admin session", token) |> Base.url_encode64(padding: false)
    end
  end

  @doc "Whether a login stored as `fingerprint` at unix time `at` still holds at `now`."
  def valid_login?(fingerprint, at, now \\ System.system_time(:second))

  def valid_login?(fingerprint, at, now) when is_binary(fingerprint) and is_integer(at) do
    current = fingerprint()

    is_binary(current) and Plug.Crypto.secure_compare(fingerprint, current) and
      now - at < Config.get(:admin_session_ttl) and at <= now
  end

  def valid_login?(_fingerprint, _at, _now), do: false

  ## Reads

  @doc """
  Every session still in the database — the open ones and the closed ones within the
  retention —, most recently active first, each with `agents_active`, `agents_total`,
  `threads_total` and `threads_open` (pending or processing).
  """
  def list_sessions do
    agents =
      from a in Agent,
        group_by: a.session_id,
        select: %{
          session_id: a.session_id,
          total: count(a.id),
          active: sum(fragment("CASE WHEN ? = 'active' THEN 1 ELSE 0 END", a.status))
        }

    threads =
      from t in Thread,
        group_by: t.session_id,
        select: %{
          session_id: t.session_id,
          total: count(t.id),
          open:
            sum(fragment("CASE WHEN ? IN ('pending', 'processing') THEN 1 ELSE 0 END", t.status))
        }

    from(s in Session,
      left_join: a in subquery(agents),
      on: a.session_id == s.id,
      left_join: t in subquery(threads),
      on: t.session_id == s.id,
      order_by: [desc: s.status, desc: s.last_activity_at],
      select: %{
        session: s,
        agents_active: coalesce(a.active, 0),
        agents_total: coalesce(a.total, 0),
        threads_total: coalesce(t.total, 0),
        threads_open: coalesce(t.open, 0)
      }
    )
    |> Repo.all()
  end

  @doc "The session with `code` (normalized like a join), or `nil`."
  def get_session(code) when is_binary(code) do
    case C3.Credentials.normalize_code(code) do
      {:ok, code} -> Sessions.get_session_by_code(code)
      _ -> nil
    end
  end

  @doc "The threads of a session with their derived state: `[{thread, state}]`."
  def list_threads(%Session{} = session) do
    threads = Threads.list_threads(session, preload: [:opened_by_agent])
    states = Threads.states(threads)
    Enum.map(threads, &{&1, Map.fetch!(states, &1.id)})
  end

  @doc "Thread `T<number>` of a session with its messages, or `nil`."
  def get_thread(%Session{} = session, number) do
    with %Thread{} = thread <- Threads.get_thread(session, number) do
      {Repo.preload(thread, :opened_by_agent), Threads.list_messages(thread)}
    end
  end

  @doc "The bans in force."
  defdelegate list_active_bans, to: Security

  ## Actions

  @doc "Closes an open session as the admin. `{:error, :session_closed}` if it was not open."
  def close_session(%Session{id: id}) do
    Repo.transaction(fn -> Sessions.close_session!(id, :admin, :admin, DateTime.utc_now()) end)
  end

  @doc "Revokes an active agent. `{:ok, released}` or `{:error, :not_active}`."
  def revoke_agent(%Agent{} = agent), do: Sessions.revoke(agent)

  @doc "Lifts the bans of `ip`. Returns how many it lifted."
  def unban(ip) when is_binary(ip) do
    lifted = Security.unban(ip)
    Events.notify_admin({:unbanned, ip})
    {:ok, lifted}
  end

  @doc "Purges a closed session now. `{:error, :not_closed}` for an open one."
  def purge_session(%Session{id: id}) do
    with {:ok, _} <- Lifecycle.purge_session(id) do
      Events.notify_admin({:purged, id})
      :ok
    end
  end
end
