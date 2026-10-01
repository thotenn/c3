defmodule C3.Sessions do
  @moduledoc """
  Sessions, their agents and the agents' idempotency keys: create, join, leave, close and
  the join lock.

  Every write that moves a counter (`next_agent_number`, `event_seq`) runs in one
  transaction with an atomic `UPDATE … SET n = n + 1`, so no session process is needed yet.
  Security checks (bans, failures, the lock) live in `C3.Security`; this module decides when
  to apply them.
  """
  import Ecto.Query

  alias C3.{Config, Credentials, Events, Repo, Security}
  alias C3.Sessions.{Agent, IdempotencyKey, Session}
  alias C3.Threads.{Message, Thread}

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
      insert_session(attrs["label"], secret_hash, agent_label, meta, now, secret, 3)
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
    * `{:error, :invalid_secret}` — the IP is banned until midnight, `security.join_failed`
      goes to the session, and enough distinct IPs lock its joins.
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
        ban = Security.ban(failure.ip, :invalid_secret, session.code, now)

        Events.append!(session, :security_join_failed,
          payload: %{
            ip: failure.ip,
            user_agent: failure.user_agent,
            attempted_label: failure.attempted_label,
            at: now
          }
        )

        maybe_lock_joins(session, now)
        ban
      end)

    Security.cache_ban(ban)
    {:error, :invalid_secret}
  end

  # Failures before the last unlock do not count again, or the next one would relock at once.
  defp maybe_lock_joins(session, now) do
    since = Events.last_at(session, :session_joins_unlocked)
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
  def unlock_joins(%Agent{} = agent) do
    now = now()

    Repo.transaction(fn ->
      {unlocked, _} =
        Session
        |> where([s], s.id == ^agent.session_id and not is_nil(s.joins_locked_at))
        |> Repo.update_all(set: [joins_locked_at: nil, updated_at: now])

      if unlocked == 1 do
        Events.append!(%Session{id: agent.session_id}, :session_joins_unlocked,
          actor: agent,
          payload: %{by: agent.name}
        )
      end

      unlocked == 1
    end)
  end

  @doc """
  The agent leaves: its token stops working and its `claimed` requests go back to `open`.
  Returns `{:ok, released}` with the `T<thread>.<message>` refs it released.
  """
  def leave(%Agent{} = agent) do
    now = now()

    Repo.transaction(fn ->
      agent |> Agent.changeset(%{status: :left, left_at: now}) |> Repo.update!()

      claimed =
        from m in Message,
          where: m.claimed_by_agent_id == ^agent.id and m.request_state == :claimed

      released =
        claimed
        |> join(:inner, [m], t in Thread, on: t.id == m.thread_id)
        |> order_by([m, t], [t.number, m.number])
        |> select([m, t], fragment("'T' || ? || '.' || ?", t.number, m.number))
        |> Repo.all()

      # threads.status is a cache of the derived state; recomputing it is the session
      # server's job (F3). Until then nothing can claim a request.
      Repo.update_all(claimed,
        set: [request_state: :open, claimed_by_agent_id: nil, claimed_at: nil]
      )

      Events.append!(%Session{id: agent.session_id}, :agent_left,
        actor: agent,
        payload: %{name: agent.name, released: released}
      )

      released
    end)
  end

  @doc """
  Closes the agent's session for good: every active token is revoked and from then on every
  route of the session answers `410`. `{:error, :session_closed}` if it already was.
  """
  def close(%Agent{} = agent) do
    now = now()

    Repo.transaction(fn ->
      {closed, _} =
        Session
        |> where([s], s.id == ^agent.session_id and s.status == :open)
        |> Repo.update_all(
          set: [
            status: :closed,
            closed_at: now,
            closed_by: agent.name,
            close_reason: :manual,
            updated_at: now
          ]
        )

      if closed == 0, do: Repo.rollback(:session_closed)

      Agent
      |> where([a], a.session_id == ^agent.session_id and a.status == :active)
      |> Repo.update_all(set: [status: :revoked, left_at: now, updated_at: now])

      session = Repo.get!(Session, agent.session_id)

      Events.append!(session, :session_closed,
        actor: agent,
        payload: %{closed_by: agent.name, reason: :manual}
      )

      Repo.reload!(session)
    end)
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
