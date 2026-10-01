defmodule C3.Threads.Targets do
  @moduledoc """
  The `to` of a request: an agent name (`"AG2"`), a list of them, `"label:<x>"` or `"any"`
  (also when omitted). Each target becomes one request (`schema.md`, *Un request = un
  destinatario*); a list may mix kinds and repeats are dropped.

  A named agent must be in the session and active, and nobody addresses themselves (`any`
  already excludes the author). A label needs no current holder: an agent with it may join
  later.
  """
  import Ecto.Query

  alias C3.Repo
  alias C3.Sessions.Agent

  @type t :: {:agent, Agent.t()} | {:label, String.t()} | :any

  @doc """
  Resolves `to` for a request written by `author`: `{:ok, targets}` or
  `{:error, {:invalid, message, details}}`.
  """
  @spec resolve(term(), Agent.t()) :: {:ok, [t()]} | {:error, {:invalid, String.t(), map()}}
  def resolve(nil, author), do: resolve("any", author)
  def resolve(to, author) when is_binary(to), do: resolve([to], author)
  def resolve([], _author), do: invalid("to names no target")

  def resolve(to, %Agent{} = author) when is_list(to) do
    with {:ok, parsed} <- parse_all(to) do
      parsed = Enum.uniq(parsed)
      names = for {:name, name} <- parsed, do: name
      agents = load_agents(author.session_id, names)

      Enum.reduce_while(parsed, {:ok, []}, fn target, {:ok, acc} ->
        case check(target, agents, author) do
          {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, targets} -> {:ok, Enum.reverse(targets)}
        error -> error
      end
    end
  end

  def resolve(_to, _author), do: invalid("to must be a string or a list of strings")

  @doc "The display form of a request's target: `\"AG2\"`, `\"label:backend\"` or `\"any\"`."
  def display(:agent, _label, name), do: name
  def display(:label, label, _name), do: "label:" <> label
  def display(:any, _label, _name), do: "any"

  defp parse_all(to) do
    Enum.reduce_while(to, {:ok, []}, fn item, {:ok, acc} ->
      case parse(item) do
        {:ok, target} -> {:cont, {:ok, [target | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse(item) when is_binary(item) do
    item = String.trim(item)

    cond do
      String.downcase(item) == "any" ->
        {:ok, :any}

      String.starts_with?(item, "label:") ->
        label = String.replace_prefix(item, "label:", "")

        if Regex.match?(Agent.label_format(), label),
          do: {:ok, {:label, label}},
          else: invalid("#{inspect(item)} is not a valid label target", item)

      Regex.match?(~r/^ag[1-9][0-9]*$/i, item) ->
        {:ok, {:name, String.upcase(item)}}

      true ->
        invalid("#{inspect(item)} is not an agent name, label:<x> or any", item)
    end
  end

  defp parse(item), do: invalid("every target must be a string", inspect(item))

  defp load_agents(_session_id, []), do: %{}

  defp load_agents(session_id, names) do
    Agent
    |> where([a], a.session_id == ^session_id and a.name in ^names)
    |> Repo.all()
    |> Map.new(&{&1.name, &1})
  end

  defp check({:name, name}, agents, author) do
    case agents do
      %{^name => %Agent{id: id}} when id == author.id -> invalid("cannot address yourself", name)
      %{^name => %Agent{status: :active} = agent} -> {:ok, {:agent, agent}}
      %{^name => %Agent{}} -> invalid("#{name} is no longer in the session", name)
      %{} -> invalid("#{name} is not in the session", name)
    end
  end

  defp check(target, _agents, _author), do: {:ok, target}

  defp invalid(message, target \\ nil) do
    details = if target, do: %{to: [message], target: target}, else: %{to: [message]}
    {:error, {:invalid, message, details}}
  end
end
