defmodule C3.Security do
  @moduledoc """
  Failed joins, IP bans and the per-session join lock (spec, *Bloqueo por número incorrecto*).

  A ban only blocks `create` and `join`: an agent already inside authenticates with its
  token and keeps working from a banned IP. Bans last until the next midnight of `C3_TZ`
  and never hit an IP of the allowlist.
  """
  import Ecto.Query

  alias C3.{Config, LocalTime, Repo}
  alias C3.Security.{BanCache, CIDR, IpBan, JoinFailure}
  alias C3.Sessions.Session

  @doc "The bans in force at `now`: not expired and not lifted."
  def list_active_bans(now \\ DateTime.utc_now()) do
    IpBan
    |> where([b], b.banned_until > ^now and is_nil(b.lifted_at))
    |> order_by(:banned_until)
    |> Repo.all()
  end

  @history_days 30

  @doc """
  Drops the security history older than #{@history_days} days: join failures, and bans that
  ended (expired or lifted) that long ago. Returns `%{join_failures: n, ip_bans: n}`.
  """
  def purge_history(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@history_days * 86_400, :second)
    {failures, _} = JoinFailure |> where([f], f.inserted_at < ^cutoff) |> Repo.delete_all()

    {bans, _} =
      IpBan
      |> where([b], b.banned_until < ^cutoff or b.lifted_at < ^cutoff)
      |> Repo.delete_all()

    %{join_failures: failures, ip_bans: bans}
  end

  @doc "When the ban of `ip` ends, or `nil` if `create`/`join` are allowed from it."
  def banned_until(ip, now \\ DateTime.utc_now()) do
    if allowlisted?(ip), do: nil, else: BanCache.banned_until(ip, now)
  end

  @doc "Whether `ip` is in the allowlist (`C3_IP_ALLOWLIST`) and can never be banned."
  def allowlisted?(ip), do: CIDR.member?(ip, Config.get(:ip_allowlist))

  @doc """
  Bans `ip` until the next local midnight, unless it is allowlisted. Returns the ban, or
  `nil` when the IP is allowlisted. Call `cache_ban/1` once the transaction commits.
  """
  def ban(ip, reason, session_code, now \\ DateTime.utc_now()) do
    unless allowlisted?(ip) do
      %IpBan{}
      |> IpBan.changeset(%{
        ip: ip,
        reason: reason,
        session_code: session_code,
        banned_until: LocalTime.next_midnight(now)
      })
      |> Repo.insert!()
    end
  end

  @doc """
  Lifts every ban of `ip` in force (`lifted_at`) and drops it from `BanCache`, so `create`
  and `join` work from it again at once. Returns how many bans it lifted; `0` is not an
  error (the ban may have just expired).
  """
  def unban(ip, now \\ DateTime.utc_now()) when is_binary(ip) do
    {lifted, _} =
      IpBan
      |> where([b], b.ip == ^ip and b.banned_until > ^now and is_nil(b.lifted_at))
      |> Repo.update_all(set: [lifted_at: now])

    BanCache.delete(ip)
    lifted
  end

  @doc "Mirrors a committed ban into ETS."
  def cache_ban(nil), do: :ok
  def cache_ban(%IpBan{ip: ip, banned_until: until}), do: BanCache.put(ip, until)

  @doc "Records a failed join. `session` is `nil` when the code does not exist."
  def record_failure(session, reason, attrs) do
    %JoinFailure{session_id: session && session.id}
    |> JoinFailure.changeset(
      attrs
      |> Map.put(:reason, reason)
      |> Map.update(:attempted_code, "", &String.slice(to_string(&1), 0, 32))
    )
    |> Repo.insert!()
  end

  @doc "How many unknown codes `ip` has tried since the local day started."
  def unknown_codes_today(ip, now \\ DateTime.utc_now()) do
    since = LocalTime.day_start(now)

    JoinFailure
    |> where([f], f.ip == ^ip and f.reason == :unknown_code and f.inserted_at >= ^since)
    |> select([f], count(f.id))
    |> Repo.one()
  end

  @doc "How many distinct IPs sent a wrong secret to `session` after `since` (`nil` = ever)."
  def invalid_secret_ips(%Session{id: session_id}, since) do
    JoinFailure
    |> where([f], f.session_id == ^session_id and f.reason == :invalid_secret)
    |> then(fn q -> if since, do: where(q, [f], f.inserted_at > ^since), else: q end)
    |> select([f], count(f.ip, :distinct))
    |> Repo.one()
  end
end
