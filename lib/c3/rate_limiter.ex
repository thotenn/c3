defmodule C3.RateLimiter do
  @moduledoc """
  Fixed-window request counters in ETS. Losing them on a restart is fine (`schema.md`, *Qué
  NO es una tabla*). The owning process only creates the table and drops finished windows.
  """
  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one hit of `key` in the current window of `window_ms`. `:ok` while the count stays
  within `limit`; `{:error, retry_after_seconds}` once it goes over.
  """
  def hit(key, limit, window_ms) do
    now = System.monotonic_time(:millisecond)
    window = Integer.floor_div(now, window_ms)
    counter = {key, window_ms, window}
    count = :ets.update_counter(@table, counter, 1, {counter, 0})

    if count <= limit do
      :ok
    else
      {:error, max(1, Integer.floor_div((window + 1) * window_ms - now + 999, 1000))}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    # Delete every counter whose window ended: (window + 1) * window_ms =< now.
    :ets.select_delete(@table, [
      {{{:_, :"$1", :"$2"}, :_}, [{:"=<", {:*, {:+, :"$2", 1}, :"$1"}, now}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.minutes(1))
end
