defmodule C3.Threads.Queries do
  @moduledoc """
  The reads of `C3.Threads`: threads, messages, derived state and inbox. The public functions
  are delegated from `C3.Threads`; the `@doc false` ones are shared with its writes and
  `C3.Threads.Guards`.
  """
  import Ecto.Query
  import C3.Threads.Refs

  alias C3.Repo
  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.{Derivation, Message, Targets, Thread}

  @pending [:open, :claimed]

  @doc "Thread `T<number>` of a session, or `nil`."
  def get_thread(%Session{id: session_id}, number) when is_integer(number) do
    Repo.get_by(Thread, session_id: session_id, number: number)
  end

  @doc "The thread with readable id `ref` (`T3`) in the agent's session."
  def fetch_thread(%Agent{session_id: session_id}, ref) do
    with {:ok, number} <- parse_thread_ref(ref),
         %Thread{} = thread <- Repo.get_by(Thread, session_id: session_id, number: number) do
      {:ok, thread}
    else
      _ -> {:error, :thread_not_found}
    end
  end

  @doc """
  The threads of a session, most recently active first.

  Options: `:status` keeps only the threads with that status; `:awaiting` (an `Agent`) only
  those with an open request addressed to it; `:preload` preloads.
  """
  def list_threads(%Session{id: session_id}, opts \\ []) do
    Thread
    |> where(session_id: ^session_id)
    |> filter_status(opts[:status])
    |> filter_awaiting(opts[:awaiting])
    |> order_by(desc: :last_message_at, desc: :number)
    |> preload(^Keyword.get(opts, :preload, []))
    |> Repo.all()
  end

  @doc """
  The messages of a thread, in order, with their agents and `reply_to` preloaded.

  Options: `:since` keeps only the messages after that number.
  """
  def list_messages(%Thread{id: thread_id}, opts \\ []) do
    Message
    |> where(thread_id: ^thread_id)
    |> filter_since(opts[:since])
    |> order_by(:number)
    |> Repo.all()
    |> preload_messages()
  end

  @doc "Preloads what the JSON of a thread shows (`opened_by_agent`)."
  def preload_threads(threads), do: Repo.preload(threads, :opened_by_agent)

  @doc "Preloads what the JSON of a message shows (its agents and `reply_to`)."
  def preload_messages(messages) do
    Repo.preload(messages, [
      :author_agent,
      :to_agent,
      :claimed_by_agent,
      :reply_to_message,
      attachments: from(a in C3.Threads.Attachment, order_by: a.id),
      acks: from(k in C3.Threads.MessageAck, order_by: k.id, preload: :agent)
    ])
  end

  @doc "The derived state (`C3.Threads.Derivation`) of each thread, by thread id."
  def states(threads) when is_list(threads) do
    rows = request_rows(Enum.map(threads, & &1.id))

    Map.new(threads, fn thread ->
      {thread.id, Derivation.derive(finished?(thread), Map.get(rows, thread.id, []))}
    end)
  end

  @doc "The derived state of one thread."
  def state(%Thread{} = thread), do: states([thread]) |> Map.fetch!(thread.id)

  @doc """
  What an agent has to do: the open requests addressed to it (by name, by its label or to
  `any` from someone else) and the ones it claimed, grouped by thread in thread order.
  Returns `[{thread, requests}]`, with `opened_by_agent` and the requests' agents preloaded.
  """
  def inbox(%Agent{} = me) do
    mine = dynamic([m], m.request_state == :claimed and m.claimed_by_agent_id == ^me.id)
    open = dynamic([m], m.request_state == :open and ^addressed_to(me))

    Message
    |> join(:inner, [m], t in Thread, on: t.id == m.thread_id)
    |> where([m], m.session_id == ^me.session_id and m.kind == :request)
    |> where(^dynamic([m], ^open or ^mine))
    |> order_by([m, t], [t.number, m.number])
    |> preload([m, t], thread: {t, :opened_by_agent})
    |> Repo.all()
    |> preload_messages()
    |> Enum.chunk_by(& &1.thread_id)
    |> Enum.map(fn [first | _] = requests -> {first.thread, requests} end)
  end

  @doc false
  def fetch_message(thread, ref) do
    with {:ok, number} <- parse_message_ref(thread, ref),
         %Message{} = message <-
           Message
           |> where(thread_id: ^thread.id, number: ^number)
           |> preload([:author_agent, :to_agent, :claimed_by_agent])
           |> Repo.one() do
      {:ok, message}
    else
      {:error, _} = error ->
        error

      nil ->
        {:error,
         {:invalid,
          "No message #{message_ref(thread.number, ref_number(ref))} in #{thread_ref(thread)}",
          %{message: ref}}}
    end
  end

  @doc false
  # Pending requests of the thread addressed to `me`, whoever holds them.
  def addressed_requests(thread, me) do
    Message
    |> where(
      [m],
      m.thread_id == ^thread.id and m.kind == :request and m.request_state in ^@pending
    )
    |> where(^addressed_to(me))
    |> order_by(:number)
    |> preload(:claimed_by_agent)
    |> Repo.all()
  end

  @doc false
  def addressed_to(%Agent{id: me, label: label}) do
    named_or_any =
      dynamic([m], m.to_agent_id == ^me or (m.to_target == :any and m.author_agent_id != ^me))

    if label,
      do: dynamic([m], ^named_or_any or (m.to_target == :label and m.to_label == ^label)),
      else: named_or_any
  end

  @doc false
  def request_rows([]), do: %{}

  def request_rows(thread_ids) do
    Message
    |> where([m], m.thread_id in ^thread_ids and m.kind == :request)
    |> join(:left, [m], ta in Agent, on: ta.id == m.to_agent_id)
    |> join(:left, [m], cb in Agent, on: cb.id == m.claimed_by_agent_id)
    |> order_by([m], [m.thread_id, m.number])
    |> select(
      [m, ta, cb],
      {m.thread_id, m.request_state, m.to_target, m.to_label, ta.name, cb.name}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_, state, target, label, name, claimed_by} ->
      %{state: state, to: Targets.display(target, label, name), claimed_by: claimed_by}
    end)
  end

  defp finished?(%Thread{finished_at: finished_at}), do: not is_nil(finished_at)

  ## Query filters

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: where(query, status: ^status)

  defp filter_awaiting(query, nil), do: query

  defp filter_awaiting(query, %Agent{} = me) do
    open =
      Message
      |> where([m], m.kind == :request and m.request_state == :open)
      |> where(^addressed_to(me))
      |> select([m], m.thread_id)

    where(query, [t], t.id in subquery(open))
  end

  defp filter_since(query, nil), do: query
  defp filter_since(query, number), do: where(query, [m], m.number > ^number)
end
