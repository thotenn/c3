defmodule C3.Threads.Refs do
  @moduledoc """
  The readable ids of threads and messages: `T3` and `T3.2`. Delegated from `C3.Threads`.
  """
  alias C3.Threads.{Message, Thread}

  @doc "The readable id of a thread, `T<number>`."
  def thread_ref(%Thread{number: number}), do: "T#{number}"

  @doc "The readable id of a message, `T<thread>.<number>`."
  def message_ref(%Thread{number: thread}, %Message{number: number}), do: "T#{thread}.#{number}"
  def message_ref(thread_number, number), do: "T#{thread_number}.#{number}"

  @doc "The number of a thread ref: `\"T3\"` (any case) → `{:ok, 3}`."
  def parse_thread_ref(ref) when is_binary(ref) do
    case Regex.run(~r/^[Tt]([1-9][0-9]{0,9})$/, String.trim(ref)) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> :error
    end
  end

  def parse_thread_ref(_ref), do: :error

  @doc """
  The number of a message of `thread`: `"T3.5"`, `"5"` or `5`. A ref of another thread is
  `{:error, {:invalid, …}}`.
  """
  def parse_message_ref(%Thread{number: thread}, ref) do
    case ref_parts(ref) do
      {nil, number} ->
        {:ok, number}

      {^thread, number} ->
        {:ok, number}

      {_other, _number} ->
        {:error, {:invalid, "#{ref} is not a message of T#{thread}", %{message: ref}}}

      :error ->
        {:error,
         {:invalid, "#{inspect(ref)} is not a message id like T#{thread}.2", %{message: ref}}}
    end
  end

  defp ref_parts(n) when is_integer(n) and n > 0, do: {nil, n}

  defp ref_parts(ref) when is_binary(ref) do
    case Regex.run(~r/^(?:[Tt]([1-9][0-9]{0,9})\.)?([1-9][0-9]{0,9})$/, String.trim(ref)) do
      [_, "", m] -> {nil, String.to_integer(m)}
      [_, t, m] -> {String.to_integer(t), String.to_integer(m)}
      nil -> :error
    end
  end

  defp ref_parts(_ref), do: :error

  @doc false
  def ref_number(ref) do
    case ref_parts(ref) do
      {_, n} -> n
      :error -> ref
    end
  end
end
