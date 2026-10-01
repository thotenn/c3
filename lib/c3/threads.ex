defmodule C3.Threads do
  @moduledoc """
  Threads and their messages.

  Read-only for now: opening threads, posting, claiming and finishing land in F3, written
  by the session server, which also keeps `threads.status` in sync.
  """
  import Ecto.Query

  alias C3.Repo
  alias C3.Sessions.Session
  alias C3.Threads.{Message, Thread}

  @doc "Thread `T<number>` of a session, or `nil`."
  def get_thread(%Session{id: session_id}, number) when is_integer(number) do
    Repo.get_by(Thread, session_id: session_id, number: number)
  end

  @doc """
  The threads of a session, most recently active first.

  Options: `:status` keeps only the threads with that status; `:preload` preloads.
  """
  def list_threads(%Session{id: session_id}, opts \\ []) do
    Thread
    |> where(session_id: ^session_id)
    |> filter_status(opts[:status])
    |> order_by(desc: :last_message_at, desc: :number)
    |> preload(^Keyword.get(opts, :preload, []))
    |> Repo.all()
  end

  @doc "The messages of a thread, in order."
  def list_messages(%Thread{id: thread_id}) do
    Message
    |> where(thread_id: ^thread_id)
    |> order_by(:number)
    |> Repo.all()
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: where(query, status: ^status)
end
