defmodule C3Web.V1.InboxJSON do
  @moduledoc """
  JSON for `/v1/inbox`: requests grouped by thread, the messages to acknowledge, the
  cancellations to act on (stop that work), then unseen security alerts.
  """
  alias C3.Events.Event
  alias C3.Threads
  alias C3Web.V1.ThreadJSON

  def show(%{you: you, threads: threads, to_ack: to_ack, cancelled: cancelled, alerts: alerts}) do
    %{
      you: you.name,
      empty: threads == [] and to_ack == [] and cancelled == [] and alerts == [],
      threads:
        Enum.map(threads, fn {thread, state, requests} ->
          thread
          |> ThreadJSON.summary(state)
          |> Map.put(:requests, Enum.map(requests, &request(thread, &1, you)))
        end),
      to_ack: Enum.map(to_ack, &to_ack/1),
      cancelled: Enum.map(cancelled, &cancellation/1),
      alerts: Enum.map(alerts, &alert/1)
    }
  end

  defp cancellation(%Event{payload: payload} = event) do
    payload
    |> Map.take(~w(thread request to cancelled_by claimed_by reason))
    |> Map.merge(%{"seq" => event.seq, "at" => event.inserted_at})
  end

  defp request(thread, message, you) do
    thread
    |> ThreadJSON.message(message)
    |> Map.drop([:kind, :author, :resolved_at, :acks])
    |> Map.put(:from, message.author_agent.name)
    |> put_acked(message, you)
  end

  # Whether *you* acknowledged a request that asked you to.
  defp put_acked(map, %{ack_required: true, acks: acks}, you) when is_list(acks) do
    case Enum.find(acks, &(&1.agent_id == you.id)) do
      nil -> map
      ack -> Map.put(map, :acked, not is_nil(ack.acked_at))
    end
  end

  defp put_acked(map, _message, _you), do: map

  defp to_ack(message) do
    %{
      thread: Threads.thread_ref(message.thread),
      title: message.thread.title,
      message: Threads.message_ref(message.thread, message),
      kind: message.kind,
      from: message.author_agent.name,
      importance: message.importance,
      body: message.body,
      created_at: message.inserted_at
    }
  end

  defp alert(%Event{} = event) do
    %{
      seq: event.seq,
      type: Ecto.Enum.mappings(Event, :type)[event.type],
      at: event.inserted_at,
      payload: event.payload
    }
  end
end
