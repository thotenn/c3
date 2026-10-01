defmodule C3.LocalTimeTest do
  use ExUnit.Case, async: true

  alias C3.LocalTime

  test "next midnight and day start in UTC" do
    now = ~U[2026-10-01 15:30:00.000000Z]
    assert LocalTime.next_midnight(now, "Etc/UTC") == ~U[2026-10-02 00:00:00.000000Z]
    assert LocalTime.day_start(now, "Etc/UTC") == ~U[2026-10-01 00:00:00.000000Z]
  end

  test "midnight of the local day, not of the UTC one" do
    # 02:00 UTC on Oct 2 is still Oct 1 at UTC-3.
    now = ~U[2026-10-02 02:00:00.000000Z]
    assert LocalTime.next_midnight(now, "America/Sao_Paulo") == ~U[2026-10-02 03:00:00.000000Z]
    assert LocalTime.day_start(now, "America/Sao_Paulo") == ~U[2026-10-01 03:00:00.000000Z]
  end

  test "a midnight inside a DST gap resolves to the end of the gap" do
    # Brazil started DST at 00:00 on 2018-11-04: local midnight did not exist, 01:00 -02 did.
    now = ~U[2018-11-03 18:00:00.000000Z]
    assert LocalTime.next_midnight(now, "America/Sao_Paulo") == ~U[2018-11-04 03:00:00.000000Z]
  end
end
