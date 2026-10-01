defmodule C3Web.V1.InboxJSON do
  @moduledoc """
  JSON for `/v1/inbox`: requests grouped by thread, the cancellations to act on (stop that
  work), then unseen security alerts.
  """
  alias C3.Events.Event
  alias C3Web.V1.ThreadJSON

  def show(%{you: you, threads: threads, cancelled: cancelled, alerts: alerts}) do
    %{
      you: you.name,
      empty: threads == [] and cancelled == [] and alerts == [],
      threads:
        Enum.map(threads, fn {thread, state, requests} ->
          thread
          |> ThreadJSON.summary(state)
          |> Map.put(:requests, Enum.map(requests, &request(thread, &1)))
        end),
      cancelled: Enum.map(cancelled, &cancellation/1),
      alerts: Enum.map(alerts, &alert/1)
    }
  end

  defp cancellation(%Event{payload: payload} = event) do
    payload
    |> Map.take(~w(thread request to cancelled_by claimed_by reason))
    |> Map.merge(%{"seq" => event.seq, "at" => event.inserted_at})
  end

  defp request(thread, message) do
    thread
    |> ThreadJSON.message(message)
    |> Map.drop([:kind, :author, :resolved_at])
    |> Map.put(:from, message.author_agent.name)
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
