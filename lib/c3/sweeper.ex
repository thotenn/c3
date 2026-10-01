defmodule C3.Sweeper do
  @moduledoc """
  The periodic jobs, every `sweep_interval_ms` (one minute): expire the claims of silent
  agents (`C3.Threads.expire_claims/1`) and drop idempotency keys older than a day
  (`C3.Idempotency.purge/1`). One process for the whole node; `sweeper: false` keeps it from
  starting (test).
  """
  use GenServer

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs every job once, now. What the timer calls."
  def run(now \\ DateTime.utc_now()) do
    %{
      claims_expired: C3.Threads.expire_claims(now),
      idempotency_keys_purged: C3.Idempotency.purge(now)
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
