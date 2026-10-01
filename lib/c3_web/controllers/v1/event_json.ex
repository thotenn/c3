defmodule C3Web.V1.EventJSON do
  @moduledoc """
  The event feed: each event with its readable refs (`AG2`, `T3`, `T3.2`) next to the
  payload, so the watcher can decide without another call.
  """
  alias C3.Events.Event
  alias C3.Threads

  def index(%{events: events, after: after_seq}) do
    %{
      events: Enum.map(events, &event/1),
      last_seq: if(events == [], do: after_seq, else: List.last(events).seq)
    }
  end

  @doc "One event."
  def event(%Event{} = e) do
    %{
      seq: e.seq,
      type: type(e),
      at: e.inserted_at,
      actor: e.actor_agent && e.actor_agent.name,
      thread: e.thread && Threads.thread_ref(e.thread),
      message: e.message && Threads.message_ref(e.message.thread, e.message),
      payload: e.payload
    }
  end

  @doc "The dotted type of an event (`message.posted`)."
  def type(%Event{type: type}), do: Ecto.Enum.mappings(Event, :type)[type]
end
