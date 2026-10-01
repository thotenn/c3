defmodule C3.LocalTime do
  @moduledoc """
  Day boundaries in the configured zone (`C3_TZ`): an IP ban lasts until the next local
  midnight, and the unknown-code threshold counts per local day. Every value returned is UTC.

  A midnight that falls in a DST gap resolves to the first instant after the gap; one that
  is ambiguous, to its first occurrence.
  """

  @doc "The first instant of the local day after the one `now` falls in."
  def next_midnight(%DateTime{} = now, tz \\ C3.Config.get(:tz)) do
    now |> local_date(tz) |> Date.add(1) |> midnight(tz)
  end

  @doc "The first instant of the local day `now` falls in."
  def day_start(%DateTime{} = now, tz \\ C3.Config.get(:tz)) do
    now |> local_date(tz) |> midnight(tz)
  end

  defp local_date(now, tz), do: now |> DateTime.shift_zone!(tz) |> DateTime.to_date()

  defp midnight(date, tz) do
    local =
      case DateTime.new(date, ~T[00:00:00.000000], tz) do
        {:ok, dt} -> dt
        {:gap, _before, just_after} -> just_after
        {:ambiguous, first, _second} -> first
      end

    local |> DateTime.shift_zone!("Etc/UTC") |> Map.put(:microsecond, {0, 6})
  end
end
