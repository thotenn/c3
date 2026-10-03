defmodule C3.Threads.Acks do
  @moduledoc """
  The importance of a message and the acknowledgements it asks for (C3-4). A `request` or a
  `note` is `normal`, `high` or `urgent`; with `ack_required` each of its recipients is asked to
  confirm they saw it, one `C3.Threads.MessageAck` row each, created with the message.

  The recipients are the active agents the message is addressed to when it is posted: a
  request's target (by name, the holders of its label, or every other agent for `any`); a
  note's `to`, which a note takes only to say whom it asks (`any` by default). An agent that
  joins later is not asked. Acknowledging is not answering: a request stays `open`. Claiming
  or answering a request acknowledges it for that agent.

  The functions ending in `!` run inside the caller's transaction.
  """
  import Ecto.Query
  import C3.Threads.Refs

  alias C3.{Events, Repo}
  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.{Message, MessageAck, Targets, Thread}

  @importance %{"normal" => :normal, "high" => :high, "urgent" => :urgent}
  @rank %{normal: 0, high: 1, urgent: 2}

  @doc """
  `{:ok, %{importance, ack_required}}` from a post's `attrs`, or `{:error, {:invalid, …}}`. A
  `response` takes neither: it answers, it does not ask.
  """
  def check_attrs(kind, attrs) do
    with {:ok, importance} <- importance_param(attrs["importance"]),
         {:ok, ack?} <- ack_param(attrs["ack_required"]) do
      if kind == :response and (importance != :normal or ack?),
        do: invalid(:importance, "A response takes no importance or ack_required"),
        else: {:ok, %{importance: importance, ack_required: ack?}}
    end
  end

  @doc "How urgent an importance is, to sort by: `normal` 0, `high` 1, `urgent` 2."
  def rank(importance), do: Map.fetch!(@rank, importance)

  @doc """
  The agents a message addressed to `target` (`C3.Threads.Targets`) asks to acknowledge.
  """
  def recipients(%Agent{} = author, target) do
    active = where(Agent, [a], a.session_id == ^author.session_id and a.status == :active)

    case target do
      {:agent, %Agent{} = agent} ->
        [agent]

      {:label, label} ->
        active
        |> where([a], a.label == ^label and a.id != ^author.id)
        |> order_by(:number)
        |> Repo.all()

      :any ->
        active |> where([a], a.id != ^author.id) |> order_by(:number) |> Repo.all()
    end
  end

  @doc "The targets a note's `to` names when it asks for an ack (default `any`)."
  def note_targets(to, author), do: Targets.resolve(to, author)

  @doc "Asks `recipients` to acknowledge `message`. Returns their names."
  def ask!(%Message{} = message, recipients, now) do
    rows =
      for agent <- Enum.uniq_by(recipients, & &1.id) do
        %{
          message_id: message.id,
          session_id: message.session_id,
          agent_id: agent.id,
          inserted_at: now
        }
      end

    Repo.insert_all(MessageAck, rows)
    Enum.map(Enum.uniq_by(recipients, & &1.id), & &1.name)
  end

  @doc """
  Acknowledges, for `me`, the messages of `thread` whose ack is pending: `attrs["message"]`
  (`T3.4` or `4`), or every pending one of the thread. Emits `message.acked` each. Already
  acknowledged is a no-op that still answers the message; a message that does not exist is a
  `422`, one that never asked `me`, or nothing pending, a `409`. Returns the refs, in order.
  """
  def ack!(%Agent{} = me, %Thread{} = thread, attrs, now) do
    pending =
      MessageAck
      |> join(:inner, [k], m in Message, on: m.id == k.message_id)
      |> where([k, m], k.agent_id == ^me.id and m.thread_id == ^thread.id)
      |> select([k, m], {k, m})
      |> Repo.all()

    chosen =
      case attrs["message"] do
        nil ->
          Enum.filter(pending, fn {k, _m} -> is_nil(k.acked_at) end)

        ref ->
          case C3.Threads.Queries.fetch_message(thread, ref) do
            {:ok, message} -> Enum.filter(pending, fn {_k, m} -> m.id == message.id end)
            {:error, reason} -> Repo.rollback(reason)
          end
      end

    if chosen == [] do
      Repo.rollback(
        {:conflict, "Nothing for you to acknowledge in #{thread_ref(thread)}",
         %{message: attrs["message"]}}
      )
    end

    author_names = author_names(Enum.map(chosen, fn {_k, m} -> m.author_agent_id end))

    for {k, m} <- Enum.sort_by(chosen, fn {_k, m} -> m.number end) do
      if is_nil(k.acked_at) do
        MessageAck |> where(id: ^k.id) |> Repo.update_all(set: [acked_at: now])

        Events.append!(%Session{id: thread.session_id}, :message_acked,
          actor: me,
          thread: thread,
          message: m.id,
          payload: %{
            thread: thread_ref(thread),
            message: message_ref(thread, m),
            by: me.name,
            author: Map.get(author_names, m.author_agent_id)
          }
        )
      end

      message_ref(thread, m)
    end
  end

  @doc "Acknowledges, for `me`, the pending acks of `message_ids` — on a claim or an answer."
  def ack_implicitly!(_me, [], _now), do: :ok

  def ack_implicitly!(%Agent{id: me}, message_ids, now) do
    MessageAck
    |> where([k], k.agent_id == ^me and k.message_id in ^message_ids and is_nil(k.acked_at))
    |> Repo.update_all(set: [acked_at: now])

    :ok
  end

  @doc """
  The messages `me` still has to acknowledge, except `except` (message ids the inbox already
  lists), oldest first, with their thread and author preloaded.
  """
  def pending(%Agent{id: me}, except \\ []) do
    Message
    |> join(:inner, [m], k in MessageAck, on: k.message_id == m.id)
    |> where([m, k], k.agent_id == ^me and is_nil(k.acked_at) and m.id not in ^except)
    |> order_by([m], m.id)
    |> preload([:author_agent, thread: :opened_by_agent])
    |> Repo.all()
  end

  defp author_names(ids) do
    Agent
    |> where([a], a.id in ^Enum.uniq(ids))
    |> select([a], {a.id, a.name})
    |> Repo.all()
    |> Map.new()
  end

  defp importance_param(nil), do: {:ok, :normal}

  defp importance_param(value) do
    case Map.fetch(@importance, value) do
      {:ok, importance} -> {:ok, importance}
      :error -> invalid(:importance, "importance must be normal, high or urgent")
    end
  end

  defp ack_param(nil), do: {:ok, false}
  defp ack_param(value) when is_boolean(value), do: {:ok, value}
  defp ack_param("true"), do: {:ok, true}
  defp ack_param("false"), do: {:ok, false}
  defp ack_param(_value), do: invalid(:ack_required, "ack_required must be a boolean")

  defp invalid(field, message), do: {:error, {:invalid, message, %{field => [message]}}}
end
