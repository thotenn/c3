defmodule C3.Security.BanCache do
  @moduledoc """
  ETS mirror of the bans in force (`ip_bans` is the source of truth). Loaded at boot, kept
  current by `C3.Security` and swept hourly, so every `create`/`join` checks a ban without
  touching the database.
  """
  use GenServer

  alias C3.Security

  @table __MODULE__
  @sweep_ms :timer.hours(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Records a ban; a later `until` wins over an earlier one for the same IP."
  def put(ip, %DateTime{} = until) do
    until = DateTime.to_unix(until, :microsecond)

    case :ets.lookup(@table, ip) do
      [{^ip, current}] when current >= until -> :ok
      _ -> :ets.insert(@table, {ip, until}) && :ok
    end
  end

  @doc "When the ban of `ip` ends, or `nil` if it is not banned at `now`."
  def banned_until(ip, %DateTime{} = now) do
    now = DateTime.to_unix(now, :microsecond)

    case :ets.lookup(@table, ip) do
      [{^ip, until}] when until > now -> DateTime.from_unix!(until, :microsecond)
      _ -> nil
    end
  end

  @doc "Mirrors every ban in force from `ip_bans`; what runs at boot."
  def load do
    for ban <- Security.list_active_bans(), do: put(ban.ip, ban.banned_until)
    :ok
  end

  @doc "Forgets the ban of `ip` (an unban)."
  def delete(ip), do: :ets.delete(@table, ip) && :ok

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    load()
    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.os_time(:microsecond)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
