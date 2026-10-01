defmodule C3.Events do
  @moduledoc """
  The per-session event log the watcher consumes.

  Read-only for now: events are appended by the session server (F3) and fanned out in F4.
  """
  import Ecto.Query

  alias C3.Events.Event
  alias C3.Repo
  alias C3.Sessions.Session

  @default_limit 100

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
