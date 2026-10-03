defmodule C3.Reservations.Glob do
  @moduledoc """
  Whether two reservation patterns can name the same thing: the intersection of the two
  globs is not empty. Symmetric, so a reservation of `repo:c3/lib/**` and one of
  `repo:c3/lib/c3.ex` overlap whichever came first.

  `?` is one character but `/`, `*` any run without `/`, `**` any run at all. Everything else,
  `[`, `{` and `\\` included, is literal. A directory is reserved as `dir/**`, which does not
  match `dir` itself.

  The cost is up to the product of the two lengths (a pair of 256-byte patterns full of `*`
  takes tens of milliseconds): `overlap/3` counts it against a budget the caller shares
  across all the pairs of one request.
  """

  @doc "How many wildcards (`?`, `*`, `**`) a pattern has."
  def wildcards(pattern) when is_binary(pattern),
    do: pattern |> tokens() |> Enum.count(&(&1 in [:one, :star, :globstar]))

  @doc "True when some string matches both `a` and `b`."
  def overlap?(a, b) when is_binary(a) and is_binary(b) do
    {:ok, result, _left} = overlap(a, b, :infinity)
    result
  end

  @doc """
  `overlap?/2` within `budget` steps: `{:ok, overlap?, budget_left}`, or `:too_complex` when
  the patterns need more.
  """
  def overlap(a, b, budget) when is_binary(a) and is_binary(b) do
    a = a |> tokens() |> List.to_tuple()
    b = b |> tokens() |> List.to_tuple()

    try do
      {result, memo} = overlap(a, b, 0, 0, %{budget: budget})
      {:ok, result, left(budget, map_size(memo) - 1)}
    catch
      :too_complex -> :too_complex
    end
  end

  defp left(:infinity, _used), do: :infinity
  defp left(budget, used), do: budget - used

  # Walks both patterns at once; a state is a pair of positions, and every move goes forward
  # in at least one of them. A star may match nothing (skip it), or take one more character
  # and either stay for more or end there.
  defp overlap(a, b, i, j, memo) do
    case memo do
      %{{^i, ^j} => result} ->
        {result, memo}

      %{budget: budget} when is_integer(budget) and map_size(memo) > budget ->
        throw(:too_complex)

      _ ->
        {result, memo} = any_state(a, b, moves(token(a, i), token(b, j), i, j), memo)
        {result, Map.put(memo, {i, j}, result)}
    end
  end

  defp moves(:end, :end, _i, _j), do: :match

  defp moves(ta, tb, i, j) do
    skips =
      if(star?(ta), do: [{i + 1, j}], else: []) ++ if(star?(tb), do: [{i, j + 1}], else: [])

    takes =
      if ta != :end and tb != :end and share_char?(ta, tb) do
        for ni <- after_char(ta, i), nj <- after_char(tb, j), {ni, nj} != {i, j}, do: {ni, nj}
      else
        []
      end

    skips ++ takes
  end

  defp any_state(_a, _b, :match, memo), do: {true, memo}

  defp any_state(a, b, states, memo) do
    Enum.reduce_while(states, {false, memo}, fn {i, j}, {false, memo} ->
      case overlap(a, b, i, j, memo) do
        {true, memo} -> {:halt, {true, memo}}
        {false, memo} -> {:cont, {false, memo}}
      end
    end)
  end

  defp after_char(token, i), do: if(star?(token), do: [i, i + 1], else: [i + 1])

  defp token(tokens, i) when i < tuple_size(tokens), do: elem(tokens, i)
  defp token(_tokens, _i), do: :end

  defp star?(token), do: token in [:star, :globstar]

  # Some character both tokens accept.
  defp share_char?({:char, c}, {:char, d}), do: c == d
  defp share_char?({:char, c}, other), do: accepts?(other, c)
  defp share_char?(other, {:char, c}), do: accepts?(other, c)
  defp share_char?(_a, _b), do: true

  defp accepts?(:globstar, _c), do: true
  defp accepts?(_one_or_star, c), do: c != ?/

  defp tokens(pattern), do: tokens(String.to_charlist(pattern), [])

  defp tokens([], acc), do: Enum.reverse(acc)
  defp tokens([?*, ?* | rest], acc), do: tokens(drop_stars(rest), [:globstar | acc])
  defp tokens([?* | rest], acc), do: tokens(rest, [:star | acc])
  defp tokens([?? | rest], acc), do: tokens(rest, [:one | acc])
  defp tokens([c | rest], acc), do: tokens(rest, [{:char, c} | acc])

  defp drop_stars([?* | rest]), do: drop_stars(rest)
  defp drop_stars(rest), do: rest
end
