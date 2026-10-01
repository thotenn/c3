defmodule C3.Events do
  @moduledoc """
  The per-session event log the watcher consumes.

  `append!/3` takes the next `seq` with an atomic `UPDATE … SET event_seq = event_seq + 1`
  and must run inside the caller's transaction, so the counter and the event commit together.

  ## Fan-out

  Every committed event is announced on the PubSub topic of its session as
  `{:c3_events, session_id, seq}` — only the highest `seq` of each transaction, and only
  after the commit (`C3.Repo.transaction/2` calls `publish_after/1`). The message says
  "there is something up to `seq`"; the table is the truth, so a listener queries it again.

  `wait_after/4`, the long-poll, subscribes *before* querying `seq > after`: an event
  committed before the query is in its result, one committed after it arrives as a message,
  so nothing falls between two polls. If the node dies between a commit and its publish, the
  waiter just times out, and the next poll with the same `after` returns the event.
  """
  import Ecto.Query

  alias C3.Events.Event
  alias C3.Repo
  alias C3.Sessions.Session

  @default_limit 100
  @pending {__MODULE__, :pending}
  @preloads [:actor_agent, :thread, message: :thread]

  @doc """
  Appends an event of `type` to the session with the next `seq`. Call inside a transaction.

  Options: `:actor` (an `Agent`), `:thread` and `:message` (the records the event is about,
  or their ids), `:payload` (a map).
  """
  def append!(%Session{id: session_id}, type, opts \\ []) do
    {1, [seq]} =
      Session
      |> where(id: ^session_id)
      |> select([s], s.event_seq)
      |> Repo.update_all(inc: [event_seq: 1])

    %Event{
      session_id: session_id,
      actor_agent_id: id_of(opts[:actor]),
      thread_id: id_of(opts[:thread]),
      message_id: id_of(opts[:message])
    }
    |> Event.changeset(%{seq: seq, type: type, payload: Keyword.get(opts, :payload, %{})})
    |> Repo.insert!()
    |> tap(&notify/1)
  end

  # Inside a transaction, the event waits in the process for the commit; outside, it is
  # already committed.
  defp notify(%Event{session_id: session_id, seq: seq}) do
    case Process.get(@pending) do
      nil -> broadcast(%{session_id => seq})
      pending -> Process.put(@pending, Map.update(pending, session_id, seq, &max(&1, seq)))
    end
  end

  @doc """
  Runs `fun` — an outermost transaction — and announces the events appended inside it once
  it returns `{:ok, _}`. On a rollback or a raise they are dropped. Called by
  `C3.Repo.transaction/2`.
  """
  def publish_after(fun) do
    Process.put(@pending, %{})

    try do
      result = fun.()
      pending = Process.get(@pending)
      if match?({:ok, _}, result), do: broadcast(pending)
      result
    after
      Process.delete(@pending)
    end
  end

  defp broadcast(pending) do
    for {session_id, seq} <- pending do
      Phoenix.PubSub.broadcast(C3.PubSub, topic(session_id), {:c3_events, session_id, seq})
    end

    :ok
  end

  defp topic(session_id), do: "session:#{session_id}"

  @doc "Subscribes the calling process to the session's events (`{:c3_events, id, seq}`)."
  def subscribe(%Session{id: session_id}),
    do: Phoenix.PubSub.subscribe(C3.PubSub, topic(session_id))

  @doc "Undoes `subscribe/1` and drops the announcements already in the mailbox."
  def unsubscribe(%Session{id: session_id}) do
    Phoenix.PubSub.unsubscribe(C3.PubSub, topic(session_id))
    flush(session_id)
  end

  defp flush(session_id) do
    receive do
      {:c3_events, ^session_id, _seq} -> flush(session_id)
    after
      0 -> :ok
    end
  end

  @doc """
  The long-poll: the events with `seq > after_seq`, or, if there are none yet, the first ones
  committed within `timeout_ms`; `[]` when the time runs out.

  Options: `:limit`, as in `list_after/3`; `:subscribed`, a function run between the
  subscription and the first query (tests use it to commit an event right in that gap).
  """
  def wait_after(%Session{} = session, after_seq, timeout_ms, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    :ok = subscribe(session)

    try do
      if fun = opts[:subscribed], do: fun.()

      case list_after(session, after_seq, Keyword.take(opts, [:limit])) do
        [] -> await(session, after_seq, deadline, opts)
        events -> events
      end
    after
      unsubscribe(session)
    end
  end

  defp await(%Session{id: session_id} = session, after_seq, deadline, opts) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:c3_events, ^session_id, seq} when seq <= after_seq ->
        await(session, after_seq, deadline, opts)

      {:c3_events, ^session_id, _seq} ->
        case list_after(session, after_seq, Keyword.take(opts, [:limit])) do
          [] -> await(session, after_seq, deadline, opts)
          events -> events
        end
    after
      remaining -> []
    end
  end

  defp id_of(nil), do: nil
  defp id_of(id) when is_integer(id), do: id
  defp id_of(%{id: id}), do: id

  @doc "When the last event of `type` happened in the session, or `nil`."
  def last_at(%Session{id: session_id}, type) do
    Event
    |> where(session_id: ^session_id, type: ^type)
    |> select([e], max(e.inserted_at))
    |> Repo.one()
  end

  @doc """
  The events of a session with `seq > after_seq`, in order.

  Options: `:limit` (default #{@default_limit}). The actor, thread and message come preloaded
  (the message with its thread), for the feed's readable refs.
  """
  def list_after(%Session{id: session_id}, after_seq, opts \\ []) when is_integer(after_seq) do
    Event
    |> where([e], e.session_id == ^session_id and e.seq > ^after_seq)
    |> order_by(:seq)
    |> limit(^Keyword.get(opts, :limit, @default_limit))
    |> preload(^@preloads)
    |> Repo.all()
  end
end
