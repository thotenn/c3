defmodule C3.Sweeper do
  @moduledoc """
  The periodic jobs, every `sweep_interval_ms` (one minute): expire the claims of silent
  agents (`C3.Threads.expire_claims/1`); warn, close and purge sessions
  (`C3.Sessions.Lifecycle`); drop idempotency keys older than a day
  (`C3.Idempotency.purge/1`) and the old security history (`C3.Security.purge_history/1`).
  One process for the whole node; `sweeper: false` keeps it from starting (test).

  A session already past its close gets no warning: it is just closed.
  """
  use GenServer

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs every job once, now. What the timer calls."
  def run(now \\ DateTime.utc_now()) do
    %{
      claims_expired: C3.Threads.expire_claims(now),
      sessions_warned: C3.Sessions.Lifecycle.warn_closing(now),
      sessions_closed: C3.Sessions.Lifecycle.close_expired(now),
      sessions_purged: C3.Sessions.Lifecycle.purge(now),
      idempotency_keys_purged: C3.Idempotency.purge(now),
      security_purged: C3.Security.purge_history(now)
    }
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      run()
    rescue
      error ->
        Logger.error("C3.Sweeper failed: " <> Exception.format(:error, error, __STACKTRACE__))
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, C3.Config.get(:sweep_interval_ms))
end
