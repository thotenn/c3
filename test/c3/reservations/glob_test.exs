defmodule C3.Reservations.GlobTest do
  use ExUnit.Case, async: true

  alias C3.Reservations.Glob

  @overlap [
    {"repo:c3/lib/**", "repo:c3/lib/c3.ex"},
    {"repo:c3/lib/**", "repo:c3/lib/c3/threads.ex"},
    {"repo:c3/lib/*.ex", "repo:c3/lib/c3.ex"},
    {"repo:c3/lib/*.ex", "repo:c3/**"},
    {"repo:c3/*/c3.ex", "repo:c3/lib/*"},
    {"repo:c3/lib/c?.ex", "repo:c3/lib/c3.ex"},
    {"repo:c3/**/test.exs", "repo:c3/test/**"},
    {"repo:c3/**", "repo:c3/**"},
    {"repo:*/lib/**", "repo:c3/*/x"},
    {"slot:deploy", "slot:deploy"},
    {"slot:*", "slot:deploy"},
    {"**", "repo:anything/at/all"},
    {"repo:c3/a*b*c", "repo:c3/*bc"}
  ]

  @disjoint [
    {"repo:c3/lib/**", "repo:c3/test/x.exs"},
    {"repo:c3/lib/*.ex", "repo:c3/lib/c3/threads.ex"},
    {"repo:c3/lib/**", "repo:c3/lib"},
    {"repo:c3/lib/c?.ex", "repo:c3/lib/c33.ex"},
    {"repo:c3/?", "repo:c3//"},
    {"repo:c3/**", "repo:toctoc/**"},
    {"slot:deploy", "slot:build"},
    {"slot:deploy", "repo:deploy"},
    {"repo:c3/*.ex", "repo:c3/*.exs"},
    {"repo:c3/[ab].ex", "repo:c3/a.ex"}
  ]

  test "patterns that can name the same thing overlap, in both directions" do
    for {a, b} <- @overlap do
      assert Glob.overlap?(a, b), "#{a} should overlap #{b}"
      assert Glob.overlap?(b, a), "#{b} should overlap #{a}"
    end
  end

  test "patterns that cannot do not, in both directions" do
    for {a, b} <- @disjoint do
      refute Glob.overlap?(a, b), "#{a} should not overlap #{b}"
      refute Glob.overlap?(b, a), "#{b} should not overlap #{a}"
    end
  end

  test "long patterns full of stars stay fast" do
    a = "repo:x/" <> String.duplicate("*a", 60)
    b = "repo:x/" <> String.duplicate("a*", 60) <> "b"
    {micros, result} = :timer.tc(fn -> Glob.overlap?(a, b) end)
    refute result
    assert micros < 2_000_000
  end
end
