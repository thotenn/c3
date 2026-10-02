defmodule C3.Sessions do
  @moduledoc """
  Sessions, their agents and the agents' idempotency keys: create, join, leave, close and
  the join lock.

  Every write that moves a counter (`next_agent_number`, `event_seq`) runs in one
  transaction with an atomic `UPDATE … SET n = n + 1`, so no session process is needed (see
  `C3.Threads` for how thread writes are serialized).
  Security checks (bans, failures, the lock) live in `C3.Security`; this module decides when
  to apply them.
  """
  import Ecto.Query

  alias C3.{Config, Credentials, Events, Metrics, Repo, Security, Threads}
  alias C3.Sessions.{Agent, IdempotencyKey, Session}

  @type meta :: %{ip: String.t(), user_agent: String.t() | nil}

  @doc "The session with the public `code`, or `nil`."
  def get_session_by_code(code) when is_binary(code), do: Repo.get_by(Session, code: code)

  @doc "The agent whose token hashes to `token_hash`, with its session preloaded, or `nil`."
  def get_agent_by_token_hash(token_hash) when is_binary(token_hash) do
    Agent
    |> where(token_hash: ^token_hash)
    |> preload(:session)
    |> Repo.one()
  end

  @doc "The agent that owns the clear `token`, with its session, or `nil`."
  def get_agent_by_token(token) when is_binary(token) do
    token |> Credentials.hash_token() |> get_agent_by_token_hash()
  end

  @doc "The agents of a session, in join order."
  def list_agents(%Session{id: session_id}) do
    Agent
    |> where(session_id: ^session_id)
    |> order_by(:number)
    |> Repo.all()
  end

  @doc "The stored response for `key` of an agent, or `nil`."
  def get_idempotency_key(%Agent{id: agent_id}, key) when is_binary(key) do
    Repo.get_by(IdempotencyKey, agent_id: agent_id, key: key)
  end

  @doc """
  Creates a session and its first agent, `AG1`.

  `attrs`: `"label"` and `"agent_label"`, both optional. Returns
  `{:ok, %{session, agent, secret, token}}` — the only place the clear secret and token
  exist — or `{:error, :ip_banned, until}` / `{:error, changeset}`.
  """
  def create_session(attrs, %{ip: ip} = meta) do
    now = now()

    with :ok <- check_ban(ip, now),
         {:ok, agent_label} <- validate_agent_label(attrs) do
      secret = Credentials.generate_secret()
      secret_hash = Credentials.hash_secret(secret)

      with {:ok, _} = created <-
             insert_session(attrs["label"], secret_hash, agent_label, meta, now, secret, 3) do
        Metrics.emit([:session, :created])
        created
      end
    end
  end

  # A code collision (40 bits) is astronomically rare, but it rolls back and retries
  # instead of reusing a transaction after a constraint error, which Postgres would abort.
  defp insert_session(label, secret_hash, agent_label, meta, now, secret, attempts) do
    result =
      Repo.transaction(fn ->
        session =
          %Session{}
          |> Session.changeset(%{
            code: Credentials.generate_code(),
            secret_hash: secret_hash,
            label: label,
            expires_at: DateTime.add(now, Config.get(:session_max_ttl))
          })
          |> Repo.insert()
          |> rollback_on_error()

        {agent, token} = add_agent!(session, agent_label, meta)
        %{session: Repo.reload!(session), agent: agent, secret: secret, token: token}
      end)

    case result do
      {:error, %Ecto.Changeset{errors: [code: _]}} when attempts > 1 ->
        insert_session(label, secret_hash, agent_label, meta, now, secret, attempts - 1)

      other ->
        other
    end
  end

  @doc """
  Joins the session `code` with its `secret`.

  `attrs`: `"secret"` and an optional `"agent_label"`. Returns `{:ok, %{session, agent,
  token}}` or one of:

    * `{:error, :ip_banned, until}` — the IP is banned; nothing is recorded.
    * `{:error, :not_found}` — unknown code; counts toward the IP's daily threshold.
    * `{:error, :session_closed}` / `{:error, :joins_locked}` — recorded, never banned. A
      locked session does not check the secret, so it does not leak whether it was right.
    * `{:error, :invalid_secret}` — `security.join_failed` goes to the session and enough
      distinct subjects lock its joins. Past `C3_SECRET_TOLERANCE` failures of the subject
      in the session the subject is banned, for longer each time (`C3.Security`).
    * `{:error, changeset}` — invalid `agent_label`.
  """
  def join_session(code, attrs, %{ip: ip} = meta) do
    now = now()

    with :ok <- check_ban(ip, now),
         {:ok, agent_label} <- validate_agent_label(attrs) do
      failure = %{
        ip: ip,
        attempted_code: code,
        attempted_label: agent_label,
        user_agent: meta[:user_agent]
      }

      with {:ok, normalized} <- Credentials.normalize_code(code),
           %Session{} = session <- get_session_by_code(normalized) do
        join_existing(session, attrs["secret"], agent_label, meta, failure, now)
      else
        _ -> unknown_code(failure, now)
      end
    end
  end

  defp join_existing(%Session{status: :closed} = session, _secret, _label, _meta, failure, _now) do
    Security.record_failure(session, :session_closed, failure)
    {:error, :session_closed}
  end

  defp join_existing(%Session{joins_locked_at: %DateTime{}} = session, _, _, _, failure, _now) do
    Security.record_failure(session, :joins_locked, failure)
    {:error, :joins_locked}
  end

  defp join_existing(session, secret, agent_label, meta, failure, now) do
    if Credentials.verify_secret(secret, session.secret_hash) do
      Repo.transaction(fn ->
        {agent, token} = add_agent!(session, agent_label, meta)
        %{session: Repo.reload!(session), agent: agent, token: token}
      end)
    else
      invalid_secret(session, failure, now)
    end
  end

  defp unknown_code(failure, now) do
    Credentials.dummy_verify()

    {:ok, ban} =
      Repo.transaction(fn ->
        Security.record_failure(nil, :unknown_code, failure)

        if Security.unknown_codes_today(failure.ip, now) >= Config.get(:unknown_code_limit) do
          Security.ban(failure.ip, :unknown_code, nil, now)
        end
      end)

    Security.cache_ban(ban)
    {:error, :not_found}
  end

  defp invalid_secret(session, failure, now) do
    {:ok, ban} =
      Repo.transaction(fn ->
        Security.record_failure(session, :invalid_secret, failure)
        since = last_reset_at(session)

        ban =
          if Security.secret_failures(failure.ip, session, since) >
               Config.get(:secret_tolerance) do
            until = Security.secret_ban_until(failure.ip, session.code, now)
            Security.ban(failure.ip, :invalid_secret, session.code, now, until)
          end

        Events.append!(session, :security_join_failed,
          payload: %{
            ip: failure.ip,
            subject: C3.Security.CIDR.subject(failure.ip),
            banned_until: ban && ban.banned_until,
            user_agent: failure.user_agent,
            attempted_label: failure.attempted_label,
            at: now
          }
        )

        maybe_lock_joins(session, since, now)
        ban
      end)

    Security.cache_ban(ban)
    {:error, :invalid_secret}
  end

  # Failures before the last unlock or rotation do not count again, or the next one would
  # relock (or ban) at once.
  defp last_reset_at(session) do
    [:session_joins_unlocked, :session_secret_rotated]
    |> Enum.map(&Events.last_at(session, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp maybe_lock_joins(session, since, now) do
    ips = Security.invalid_secret_ips(session, since)

    if ips >= Config.get(:join_lock_ips) do
      {locked, _} =
        Session
        |> where([s], s.id == ^session.id and is_nil(s.joins_locked_at))
        |> Repo.update_all(set: [joins_locked_at: now, updated_at: now])

      if locked == 1 do
        Events.append!(session, :session_joins_locked, payload: %{distinct_ips: ips})
      end
    end
  end

  @doc """
  Lifts the join lock of the agent's session. Idempotent: `{:ok, false}` when it was not
  locked, `{:ok, true}` when this call unlocked it.
  """
  def unlock_joins(%Agent{} = agent), do: unlock_joins(%Session{id: agent.session_id}, agent)

  @doc "`unlock_joins/1` as `by` — an agent, or `:admin` for the admin pages."
  def unlock_joins(%Session{id: session_id}, by) do
    now = now()
    {actor, name} = if by == :admin, do: {nil, "admin"}, else: {by, by.name}

    Repo.transaction(fn ->
      {unlocked, _} =
        Session
        |> where([s], s.id == ^session_id and s.status == :open and not is_nil(s.joins_locked_at))
        |> Repo.update_all(set: [joins_locked_at: nil, updated_at: now])

      if unlocked == 1 do
        Events.append!(%Session{id: session_id}, :session_joins_unlocked,
          actor: actor,
          payload: %{by: name}
        )
      end

      unlocked == 1
    end)
  end

  @doc """
  Rotates the security number of the agent's session: the old one stops working for joins,
  the agents already in keep their tokens, and a join lock is lifted — a lock protects the
  old number, and the new one has not been tried by anyone. Failures before the rotation no
  longer count toward a new lock. Emits `session.secret_rotated` (`by`, `unlocked`), never
  with the number. Returns `{:ok, %{secret, unlocked}}`, the only place the new number exists.
  """
  def rotate_secret(%Agent{} = agent) do
    now = now()
    secret = Credentials.generate_secret()
    secret_hash = Credentials.hash_secret(secret)

    Repo.transaction(fn ->
      session = Repo.get!(Session, agent.session_id)
      if session.status == :closed, do: Repo.rollback(:session_closed)
      unlocked = not is_nil(session.joins_locked_at)

      Session
      |> where(id: ^session.id)
      |> Repo.update_all(set: [secret_hash: secret_hash, joins_locked_at: nil, updated_at: now])

      Events.append!(session, :session_secret_rotated,
        actor: agent,
        payload: %{by: agent.name, unlocked: unlocked}
      )

      %{secret: secret, unlocked: unlocked}
    end)
  end

  @doc """
  The agent leaves: its token stops working and its `claimed` requests go back to `open`, with
  the status of their threads recomputed in the same transaction. Returns `{:ok, released}`
  with the `T<thread>.<message>` refs it released.
  """
  def leave(%Agent{} = agent) do
    now = now()

    Repo.transaction(fn ->
      agent |> Agent.changeset(%{status: :left, left_at: now}) |> Repo.update!()
      {released, thread_ids} = Threads.release_claims!(agent)

      Events.append!(%Session{id: agent.session_id}, :agent_left,
        actor: agent,
        payload: %{name: agent.name, released: released}
      )

      Threads.refresh_threads!(thread_ids, agent)
      released
    end)
  end

  @doc """
  The admin revokes an agent: like `leave/1` — its token stops working and its claims go
  back to `open` — but the agent ends `revoked`, not `left`, and the event is
  `agent.revoked`, with `by: "admin"`. Returns `{:ok, released}`, or `{:error,
  :not_active}` when the agent had already left, been revoked or its session closed.
  """
  def revoke(%Agent{} = agent) do
    now = now()

    Repo.transaction(fn ->
      {revoked, _} =
        Agent
        |> where([a], a.id == ^agent.id and a.status == :active)
        |> Repo.update_all(set: [status: :revoked, left_at: now, updated_at: now])

      if revoked == 0, do: Repo.rollback(:not_active)

      {released, thread_ids} = Threads.release_claims!(agent)

      Events.append!(%Session{id: agent.session_id}, :agent_revoked,
        payload: %{name: agent.name, by: "admin", released: released}
      )

      Threads.refresh_threads!(thread_ids, nil)
      released
    end)
  end

  @doc """
  Closes the agent's session for good: every active token is revoked and from then on every
  route of the session answers `410`. `{:error, :session_closed}` if it already was.
  """
  def close(%Agent{} = agent) do
    Repo.transaction(fn ->
      close_session!(agent.session_id, :manual, agent, DateTime.utc_now())
    end)
  end

  @doc """
  Closes the open session `session_id` inside the caller's transaction: status, `closed_at`,
  `closed_by` (the actor's name; `"system"` for `nil`, `"admin"` for `:admin`) and `reason`, every active token revoked and
  `session.closed` emitted. Rolls back with `:session_closed` if it was not open, or if
  `where` (an extra condition on the session row, e.g. still idle) does not hold. Returns
  the session.
  """
  def close_session!(session_id, reason, actor, now, where \\ dynamic(true)) do
    {closed_by, actor} =
      case actor do
        nil -> {"system", nil}
        :admin -> {"admin", nil}
        %Agent{name: name} -> {name, actor}
      end

    {closed, _} =
      Session
      |> where([s], s.id == ^session_id and s.status == :open)
      |> where(^where)
      |> Repo.update_all(
        set: [
          status: :closed,
          closed_at: now,
          closed_by: closed_by,
          close_reason: reason,
          updated_at: now
        ]
      )

    if closed == 0, do: Repo.rollback(:session_closed)
    Metrics.emit([:session, :closed], %{reason: reason})

    Agent
    |> where([a], a.session_id == ^session_id and a.status == :active)
    |> Repo.update_all(set: [status: :revoked, left_at: now, updated_at: now])

    session = Repo.get!(Session, session_id)

    Events.append!(session, :session_closed,
      actor: actor,
      payload: %{closed_by: closed_by, reason: reason}
    )

    Repo.reload!(session)
  end

  @alert_types [:security_join_failed, :session_joins_locked]

  @doc """
  What the agent has not seen yet, oldest first, and marks it seen — `/inbox` shows each one
  once:

    * the security alerts of its session (`security.join_failed`, `session.joins_locked`);
    * the `request.cancelled` of requests it was working on or could have taken: claimed by
      it, addressed to it, to its label, or to `any` from someone else. Its own cancellations
      are left out.
  """
  def take_notices(%Agent{} = agent) do
    events =
      C3.Events.Event
      |> where([e], e.session_id == ^agent.session_id and e.seq > ^agent.alerts_seen_seq)
      |> where([e], e.type in ^[:request_cancelled | @alert_types])
      |> order_by(:seq)
      |> Repo.all()

    with [_ | _] <- events do
      last = List.last(events).seq

      Agent
      |> where([a], a.id == ^agent.id and a.alerts_seen_seq < ^last)
      |> Repo.update_all(set: [alerts_seen_seq: last])
    end

    Enum.filter(events, &(&1.type in @alert_types or cancelled_for?(&1.payload, agent)))
  end

  defp cancelled_for?(%{"cancelled_by" => name}, %Agent{name: name}), do: false

  defp cancelled_for?(payload, %Agent{name: name, label: label}) do
    case payload do
      %{"claimed_by" => ^name} -> true
      %{"to" => ^name} -> true
      %{"to" => "any", "author" => author} -> author != name
      %{"to" => "label:" <> target} -> target == label
      _ -> false
    end
  end

  @doc """
  Records that the agent was seen at `now`, at most once per `last_seen_throttle` seconds
  (every authenticated request counts, but not every one writes). Returns the agent, updated
  or not.
  """
  def touch_seen(%Agent{} = agent, now \\ DateTime.utc_now()) do
    if DateTime.diff(now, agent.last_seen_at, :second) >= Config.get(:last_seen_throttle) do
      Agent |> where(id: ^agent.id) |> Repo.update_all(set: [last_seen_at: now])
      %{agent | last_seen_at: now}
    else
      agent
    end
  end

  @doc """
  Records activity on the session at `now` — what postpones its close for inactivity
  (`session_idle_ttl`). Throttled like `touch_seen/2`. Returns the session, updated or not.
  """
  def touch_activity(%Session{} = session, now \\ DateTime.utc_now()) do
    if DateTime.diff(now, session.last_activity_at, :second) >= Config.get(:last_seen_throttle) do
      Session
      |> where([s], s.id == ^session.id and s.last_activity_at < ^now)
      |> Repo.update_all(set: [last_activity_at: now])

      %{session | last_activity_at: now}
    else
      session
    end
  end

  defp add_agent!(%Session{id: session_id} = session, label, meta) do
    {1, [next]} =
      Session
      |> where(id: ^session_id)
      |> select([s], s.next_agent_number)
      |> Repo.update_all(inc: [next_agent_number: 1])

    number = next - 1
    token = Credentials.generate_token()

    agent =
      %Agent{session_id: session_id}
      |> Agent.changeset(%{
        number: number,
        name: "AG#{number}",
        label: label,
        token_hash: Credentials.hash_token(token),
        joined_ip: meta.ip,
        user_agent: meta[:user_agent] && String.slice(meta.user_agent, 0, 500)
      })
      |> Repo.insert()
      |> rollback_on_error()

    Events.append!(session, :agent_joined,
      actor: agent,
      payload: %{name: agent.name, label: agent.label}
    )

    {agent, token}
  end

  defp check_ban(ip, now) do
    case Security.banned_until(ip, now) do
      nil -> :ok
      until -> {:error, :ip_banned, until}
    end
  end

  defp validate_agent_label(attrs) do
    case attrs["agent_label"] do
      nil ->
        {:ok, nil}

      label ->
        types = %{agent_label: :string}

        {%{}, types}
        |> Ecto.Changeset.cast(%{agent_label: label}, [:agent_label])
        |> Ecto.Changeset.validate_format(:agent_label, Agent.label_format())
        |> Ecto.Changeset.apply_action(:validate)
        |> case do
          {:ok, %{agent_label: label}} -> {:ok, label}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp rollback_on_error({:ok, record}), do: record
  defp rollback_on_error({:error, changeset}), do: Repo.rollback(changeset)

  defp now, do: DateTime.utc_now()
end
