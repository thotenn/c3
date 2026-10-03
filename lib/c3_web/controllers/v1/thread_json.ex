defmodule C3Web.V1.ThreadJSON do
  @moduledoc """
  JSON for threads and messages. Only readable ids leave: threads `T3`, messages `T3.5`,
  agents `AG2`. `status` is the cached one; `awaiting` and `processing_by` are derived.
  """
  alias C3.Threads
  alias C3.Threads.{Attachment, Message, MessageAck, Targets}

  def index(%{threads: threads, states: states}) do
    %{threads: Enum.map(threads, &summary(&1, Map.fetch!(states, &1.id)))}
  end

  def show(%{thread: thread, state: state, messages: messages}) do
    thread |> summary(state) |> Map.put(:messages, Enum.map(messages, &message(thread, &1)))
  end

  def posted(%{thread: {thread, state}, messages: messages, resolved: resolved}) do
    %{
      thread: summary(thread, state),
      messages: Enum.map(messages, &message(thread, &1)),
      resolved: resolved
    }
  end

  def action(%{thread: {thread, state}, extra: extra}) do
    Map.put(extra, :thread, summary(thread, state))
  end

  @doc "A thread without its messages."
  def summary(thread, state) do
    %{
      id: Threads.thread_ref(thread),
      title: thread.title,
      status: thread.status,
      opened_by: thread.opened_by_agent.name,
      awaiting: state.awaiting,
      processing_by: state.processing_by,
      created_at: thread.inserted_at,
      last_message_at: thread.last_message_at,
      finished_at: thread.finished_at
    }
  end

  @doc "The metadata of an attachment (its content is at `GET /v1/attachments/{id}`)."
  def attachment(%Attachment{} = a) do
    %{
      id: a.id,
      filename: a.filename,
      content_type: a.content_type,
      size_bytes: a.size_bytes,
      sha256: a.sha256
    }
  end

  defp attachments(%Message{attachments: list}) when is_list(list),
    do: Enum.map(list, &attachment/1)

  defp attachments(%Message{}), do: []

  # Who was asked to acknowledge, and when they did: only on a message that asked.
  defp put_acks(map, %Message{ack_required: true, acks: acks}) when is_list(acks) do
    Map.put(
      map,
      :acks,
      Enum.map(acks, fn %MessageAck{} = k -> %{agent: k.agent.name, acked_at: k.acked_at} end)
    )
  end

  defp put_acks(map, %Message{}), do: map

  @doc "A message of `thread`; the request fields only on requests."
  def message(thread, %Message{} = m) do
    base =
      %{
        id: Threads.message_ref(thread, m),
        kind: m.kind,
        author: m.author_agent && m.author_agent.name,
        body: m.body,
        reply_to: m.reply_to_message && Threads.message_ref(thread, m.reply_to_message),
        attachments: attachments(m),
        importance: m.importance,
        ack_required: m.ack_required,
        created_at: m.inserted_at
      }
      |> put_acks(m)

    if m.kind == :request do
      Map.merge(base, %{
        to: Targets.display(m.to_target, m.to_label, m.to_agent && m.to_agent.name),
        state: m.request_state,
        claimed_by: m.claimed_by_agent && m.claimed_by_agent.name,
        resolved_at: m.resolved_at
      })
    else
      base
    end
  end
end
