defmodule C3.Events do
  @moduledoc """
  The per-session event log the watcher consumes.

  `append!/3` takes the next `seq` with an atomic `UPDATE … SET event_seq = event_seq + 1`
  and must run inside the caller's transaction, so the counter and the event commit together.
  Fan-out arrives in F4.
  """
  import Ecto.Query

  alias C3.Events.Event
  alias C3.Repo
  alias C3.Sessions.Session

  @default_limit 100

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

  Options: `:limit` (default #{@default_limit}).
  """
  def list_after(%Session{id: session_id}, after_seq, opts \\ []) when is_integer(after_seq) do
    Event
    |> where([e], e.session_id == ^session_id and e.seq > ^after_seq)
    |> order_by(:seq)
    |> limit(^Keyword.get(opts, :limit, @default_limit))
    |> Repo.all()
  end
end
