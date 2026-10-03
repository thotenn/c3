defmodule C3.Search do
  @moduledoc """
  Text search over the messages of a session (C3-4): every term of the query must appear in
  the message's body or in its thread's title, ignoring case. Plain `LIKE` on `lower()`, so the
  query is the same on SQLite and Postgres; a session is short-lived and small, and the search
  never leaves it. `%`, `_` and `\\` in a term are literal.

  `lower()` folds only ASCII on SQLite (Postgres folds everything), so a non-ASCII letter
  matches only in the case it was written.

  Errors are `{:error, {:invalid, message, details}}`.
  """
  import Ecto.Query

  alias C3.Repo
  alias C3.Sessions.Agent
  alias C3.Threads.{Message, Refs, Thread}

  @max_query_bytes 200
  @max_terms 8
  @default_limit 20
  @max_limit 100
  @snippet 160
  @kinds %{"request" => :request, "response" => :response, "note" => :note}

  @doc """
  The messages of the agent's session that match `params["q"]`, newest first, with their thread
  and author preloaded. Optional: `"thread"` (`T3`), `"kind"`, `"limit"` (default
  #{@default_limit}, at most #{@max_limit}).
  """
  def messages(%Agent{session_id: session_id}, params) do
    with {:ok, terms} <- terms_param(params["q"]),
         {:ok, thread} <- thread_param(params["thread"]),
         {:ok, kind} <- kind_param(params["kind"]),
         {:ok, limit} <- limit_param(params["limit"]) do
      query =
        Message
        |> join(:inner, [m], t in Thread, on: t.id == m.thread_id)
        |> where([m], m.session_id == ^session_id and m.kind != :system)
        |> then(&if thread, do: where(&1, [m, t], t.number == ^thread), else: &1)
        |> then(&if kind, do: where(&1, [m], m.kind == ^kind), else: &1)

      results =
        terms
        |> Enum.reduce(query, fn term, query ->
          pattern = "%" <> escape(String.downcase(term)) <> "%"

          where(
            query,
            [m, t],
            fragment("lower(?) LIKE ? ESCAPE '\\'", m.body, ^pattern) or
              fragment("lower(?) LIKE ? ESCAPE '\\'", t.title, ^pattern)
          )
        end)
        |> order_by([m], desc: m.inserted_at, desc: m.id)
        |> limit(^limit)
        |> preload([m, t], [:author_agent, thread: t])
        |> Repo.all()

      {:ok, results, terms}
    end
  end

  @doc """
  About #{@snippet} characters of `body` around the first of `terms` it contains, with `…`
  where it was cut; its start when no term is in it (the match was in the title).
  """
  def snippet(body, terms) do
    flat = String.replace(body, ~r/\s+/u, " ")
    down = String.downcase(flat)

    at =
      terms
      |> Enum.map(&:binary.match(down, String.downcase(&1)))
      |> Enum.reject(&(&1 == :nomatch))
      |> Enum.map(&elem(&1, 0))
      |> Enum.min(fn -> 0 end)

    # A byte offset of the downcased text: count graphemes up to it in the same text.
    start = max(String.length(binary_part(down, 0, at)) - div(@snippet, 3), 0)
    piece = String.slice(flat, start, @snippet)

    (if(start > 0, do: "…", else: "") <> piece) <>
      if(start + @snippet < String.length(flat), do: "…", else: "")
  end

  defp escape(term), do: String.replace(term, ["\\", "%", "_"], &("\\" <> &1))

  defp terms_param(q) when is_binary(q) do
    terms = String.split(q)

    cond do
      byte_size(q) > @max_query_bytes ->
        invalid(:q, "q is over #{@max_query_bytes} bytes")

      terms == [] ->
        invalid(:q, "q needs at least one term")

      length(terms) > @max_terms ->
        invalid(:q, "q takes at most #{@max_terms} terms")

      Enum.any?(terms, &(String.length(&1) < 2)) ->
        invalid(:q, "every term of q needs at least 2 characters")

      true ->
        {:ok, Enum.uniq(terms)}
    end
  end

  defp terms_param(_q), do: invalid(:q, "q is required: the words to search for")

  defp thread_param(nil), do: {:ok, nil}

  defp thread_param(ref) do
    case Refs.parse_thread_ref(ref) do
      {:ok, number} -> {:ok, number}
      :error -> invalid(:thread, "thread must be a thread id like T3")
    end
  end

  defp kind_param(nil), do: {:ok, nil}

  defp kind_param(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, kind} -> {:ok, kind}
      :error -> invalid(:kind, "kind must be request, response or note")
    end
  end

  defp limit_param(nil), do: {:ok, @default_limit}
  defp limit_param(n) when is_integer(n) and n in 1..@max_limit, do: {:ok, n}

  defp limit_param(n) when is_binary(n) do
    case Integer.parse(n) do
      {n, ""} -> limit_param(n)
      _ -> limit_param(0)
    end
  end

  defp limit_param(_n), do: invalid(:limit, "limit must be between 1 and #{@max_limit}")

  defp invalid(field, message), do: {:error, {:invalid, message, %{field => [message]}}}
end
