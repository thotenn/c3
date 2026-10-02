defmodule C3.Security do
  @moduledoc """
  Failed joins, IP bans and the per-session join lock (spec, *Bloqueo por número incorrecto*).

  A ban only blocks `create` and `join`: an agent already inside authenticates with its
  token and keeps working from a banned IP. A ban never hits an IP of the allowlist.

  Everything is kept per *subject* (`CIDR.subject/1`): an IPv4 address, or the IPv6 network of
  `C3_IPV6_PREFIX`. `ip` holds the subject and `ip_full` the exact address, for the admin.

  Wrong secrets: the first `C3_SECRET_TOLERANCE` of a subject in a session go without a ban.
  Past them a ban grows with the subject's secret bans of the day (`@ban_steps`: 1 min,
  10 min, 1 h) and lasts until the next midnight of `C3_TZ` once the subject was banned in
  two sessions that day. Too many unknown codes ban until midnight at once.
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

  # Seconds of the 1st, 2nd and later secret ban of a subject in a day.
  @ban_steps [60, 600, 3600]

  @doc "When the ban of `ip` ends, or `nil` if `create`/`join` are allowed from it."
  def banned_until(ip, now \\ DateTime.utc_now()) do
    if allowlisted?(ip), do: nil, else: BanCache.banned_until(CIDR.subject(ip), now)
  end

  @doc """
  Whether `ip` is in the allowlist (`C3_IP_ALLOWLIST`) and can never be banned. A subject
  network (`2001:db8::/64`) is allowlisted when the whole network is.
  """
  def allowlisted?(ip) do
    if String.contains?(ip, "/"),
      do: CIDR.block_member?(ip, Config.get(:ip_allowlist)),
      else: CIDR.member?(ip, Config.get(:ip_allowlist))
  end

  @doc """
  Bans the subject of `ip` until `until` (default: the next local midnight), unless it is
  allowlisted. Returns the ban, or `nil` when allowlisted. Call `cache_ban/1` once the
  transaction commits.
  """
  def ban(ip, reason, session_code, now \\ DateTime.utc_now(), until \\ nil) do
    unless allowlisted?(ip) do
      %IpBan{}
      |> IpBan.changeset(%{
        ip: CIDR.subject(ip),
        ip_full: ip,
        reason: reason,
        session_code: session_code,
        banned_until: until || LocalTime.next_midnight(now)
      })
      |> Repo.insert!()
      |> tap(fn _ -> C3.Metrics.emit([:ip, :banned], %{reason: reason}) end)
    end
  end

  @doc """
  Lifts every ban of `ip` in force (`lifted_at`) and drops it from `BanCache`, so `create`
  and `join` work from it again at once. `ip` is a subject network (`2001:db8::/64`) or any
  address in it. Returns how many bans it lifted; `0` is not an error (the ban may have just
  expired).
  """
  def unban(ip, now \\ DateTime.utc_now()) when is_binary(ip) do
    ip = normalize_subject(ip)

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

  @doc """
  Records a failed join. `session` is `nil` when the code does not exist. `attrs.ip` is the
  exact address; the row keeps its subject in `ip` and the address in `ip_full`.
  """
  def record_failure(session, reason, attrs) do
    %JoinFailure{session_id: session && session.id}
    |> JoinFailure.changeset(
      attrs
      |> Map.put(:reason, reason)
      |> Map.put(:ip_full, attrs.ip)
      |> Map.put(:ip, CIDR.subject(attrs.ip))
      |> Map.update(:attempted_code, "", &String.slice(to_string(&1), 0, 32))
    )
    |> Repo.insert!()
    |> tap(fn _ -> C3.Metrics.emit([:join, :failed], %{reason: reason}) end)
  end

  @doc "How many unknown codes `ip` has tried since the local day started."
  def unknown_codes_today(ip, now \\ DateTime.utc_now()) do
    since = LocalTime.day_start(now)
    ip = CIDR.subject(ip)

    JoinFailure
    |> where([f], f.ip == ^ip and f.reason == :unknown_code and f.inserted_at >= ^since)
    |> select([f], count(f.id))
    |> Repo.one()
  end

  @doc """
  How many wrong secrets the subject of `ip` sent to `session` after `since` (`nil` = ever),
  the one just recorded included.
  """
  def secret_failures(ip, %Session{id: session_id}, since) do
    ip = CIDR.subject(ip)

    JoinFailure
    |> where([f], f.session_id == ^session_id and f.ip == ^ip and f.reason == :invalid_secret)
    |> then(fn q -> if since, do: where(q, [f], f.inserted_at > ^since), else: q end)
    |> select([f], count(f.id))
    |> Repo.one()
  end

  @doc """
  When a secret ban of `ip` issued now for `session_code` ends: the next step of
  `@ban_steps` after the subject's secret bans of the day, or the next local midnight once
  the subject was banned in another session that day. Never past that midnight.
  """
  def secret_ban_until(ip, session_code, now \\ DateTime.utc_now()) do
    ip = CIDR.subject(ip)
    since = LocalTime.day_start(now)
    midnight = LocalTime.next_midnight(now)

    codes =
      IpBan
      |> where([b], b.ip == ^ip and b.reason == :invalid_secret and b.inserted_at >= ^since)
      |> select([b], b.session_code)
      |> Repo.all()

    if Enum.any?(codes, &(&1 != session_code)) do
      midnight
    else
      step = Enum.at(@ban_steps, length(codes), List.last(@ban_steps))
      Enum.min([DateTime.add(now, step, :second), midnight], DateTime)
    end
  end

  @doc "How many distinct subjects sent a wrong secret to `session` after `since` (`nil` = ever)."
  def invalid_secret_ips(%Session{id: session_id}, since) do
    JoinFailure
    |> where([f], f.session_id == ^session_id and f.reason == :invalid_secret)
    |> then(fn q -> if since, do: where(q, [f], f.inserted_at > ^since), else: q end)
    |> select([f], count(f.ip, :distinct))
    |> Repo.one()
  end

  # An address becomes its subject; a network is rewritten to its canonical subject form.
  defp normalize_subject(ip) do
    case String.split(String.trim(ip), "/", parts: 2) do
      [addr, bits] ->
        with {:ok, tuple} <- CIDR.parse_ip(addr),
             {bits, ""} <- Integer.parse(bits),
             true <- tuple_size(tuple) == 8 and bits in 0..128 do
          CIDR.subject(tuple, bits)
        else
          _ -> ip
        end

      [addr] ->
        CIDR.subject(addr)
    end
  end
end
