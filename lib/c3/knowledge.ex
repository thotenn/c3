defmodule C3.Knowledge do
  @moduledoc """
  The shared memory of a session (C3-2): short entries `K<n>` — a `decision`, `fact`,
  `constraint` or `todo` under a `topic` — that an agent records so the others can `recall`
  them instead of rereading every thread.

  Entries are never edited. A newer entry `supersedes` an active one, which becomes
  `superseded` in the same transaction; only the author can `retract` one. Superseding an
  entry that is no longer active fails, so the history of a topic stays a chain, not a tree.
  The server keeps the entries and filters them; it does not interpret them: what agents
  write is data, and each entry keeps its author and its `source` for an audit.

  Errors are `{:error, reason}` with `reason` one of `:knowledge_not_found`,
  `{:invalid, message, details}`, `{:forbidden, message}`, `{:conflict, message, details}`,
  `{:too_large, message}` or a changeset.
  """
  import Ecto.Query

  alias C3.{Events, Repo}
  alias C3.Knowledge.Entry
  alias C3.Sessions.{Agent, Session}

  @statuses %{
    "active" => [:active],
    "superseded" => [:superseded],
    "retracted" => [:retracted],
    "all" => [:active, :superseded, :retracted]
  }
  @default_limit 100
  @max_limit 500

  ## Refs

  @doc "The readable id of an entry, `K<number>`."
  def entry_ref(%Entry{number: number}), do: "K#{number}"

  @doc "The number of an entry ref: `\"K3\"` (any case) → `{:ok, 3}`."
  def parse_entry_ref(ref) when is_binary(ref) do
    case Regex.run(~r/^[Kk]([1-9][0-9]{0,9})$/, String.trim(ref)) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> :error
    end
  end

  def parse_entry_ref(_ref), do: :error

  ## Reads

  @doc """
  The entries of the agent's session, in order. `params` (strings, as the API gets them):

    * `"topic"` — that topic and the ones under it (`auth` matches `auth.jwt`)
    * `"kind"` — one kind
    * `"status"` — `active` (default), `superseded`, `retracted` or `all`
    * `"source"` — a thread (`T3`: the entries of that thread and of its messages) or a
      message (`T3.4`); the summary a thread was finished with is the entry of `T3`
    * `"limit"` — default #{@default_limit}, at most #{@max_limit}; the latest entries
  """
  def recall(%Agent{session_id: session_id}, params \\ %{}) do
    with {:ok, topic} <- topic_param(params["topic"]),
         {:ok, kind} <- kind_param(params["kind"]),
         {:ok, statuses} <- status_param(params["status"]),
         {:ok, source} <- source_param(params["source"]),
         {:ok, limit} <- limit_param(params["limit"]) do
      entries =
        Entry
        |> where([k], k.session_id == ^session_id and k.status in ^statuses)
        |> filter_topic(topic)
        |> filter_kind(kind)
        |> filter_source(source)
        |> order_by(desc: :number)
        |> limit(^limit)
        |> preload([:author_agent, :supersedes])
        |> Repo.all()
        |> Enum.reverse()

      {:ok, entries}
    end
  end

  @doc "The entry with readable id `ref` (`K3`) in the agent's session."
  def fetch_entry(%Agent{session_id: session_id}, ref) do
    with {:ok, number} <- parse_entry_ref(ref),
         %Entry{} = entry <- Repo.get_by(Entry, session_id: session_id, number: number) do
      {:ok, Repo.preload(entry, [:author_agent, :supersedes])}
    else
      _ -> {:error, :knowledge_not_found}
    end
  end

  ## Writes

  @doc """
  Records an entry: `attrs` `"topic"`, `"kind"`, `"summary"`, and optionally `"source"` (the
  thread or message it comes from, `T3` / `T3.4`) and `"supersedes"` (`K2`, an active entry of
  the session, which becomes `superseded`). Emits `knowledge.recorded`, and
  `knowledge.superseded` for the replaced entry.
  """
  def record(%Agent{} = author, attrs) do
    with {:ok, attrs} <- check_attrs(attrs) do
      Repo.transaction(fn -> record!(author, attrs) end)
    end
  end

  @doc """
  The checks of `record/2` that need no database: `{:ok, attrs}` or `{:error, reason}`. Run
  them before the transaction that calls `record!/2`.
  """
  def check_attrs(attrs) when is_map(attrs) do
    with :ok <- check_string(attrs, "summary"),
         :ok <- check_string(attrs, "topic"),
         :ok <- check_string(attrs, "kind"),
         :ok <- check_string(attrs, "source"),
         :ok <- check_summary_size(attrs["summary"]) do
      {:ok, attrs}
    end
  end

  def check_attrs(_attrs) do
    {:error, {:invalid, "record must be an object", %{record: ["must be an object"]}}}
  end

  @doc """
  `record/2` inside the caller's transaction, after `check_attrs/1`: returns the entry or
  rolls the transaction back with the reason. `C3.Threads.finish/3` uses it to record what a
  thread ended with in the same transaction as the finish.
  """
  def record!(%Agent{} = author, attrs) do
    session = %Session{id: author.session_id}
    supersedes = supersede!(author, attrs["supersedes"])

    entry =
      %Entry{
        session_id: author.session_id,
        author_agent_id: author.id,
        supersedes_id: supersedes && supersedes.id
      }
      |> Entry.changeset(%{
        number: next_number!(author.session_id),
        topic: attrs["topic"],
        kind: attrs["kind"],
        summary: attrs["summary"],
        source: attrs["source"]
      })
      |> Repo.insert()
      |> case do
        {:ok, entry} -> entry
        {:error, changeset} -> Repo.rollback(changeset)
      end

    if supersedes do
      Events.append!(session, :knowledge_superseded,
        actor: author,
        payload: %{
          entry: entry_ref(supersedes),
          topic: supersedes.topic,
          superseded_by: entry_ref(entry),
          by: author.name
        }
      )
    end

    Events.append!(session, :knowledge_recorded,
      actor: author,
      payload:
        %{
          entry: entry_ref(entry),
          topic: entry.topic,
          kind: entry.kind,
          author: author.name
        }
        |> put_present(:source, entry.source)
        |> put_present(:supersedes, supersedes && entry_ref(supersedes))
    )

    %{entry | author_agent: author, supersedes: supersedes}
  end

  @doc """
  Retracts an active entry: only its author can. `attrs` `"reason"` is optional and goes in
  the `knowledge.retracted` event. Returns `{:ok, entry}`.
  """
  def retract(%Agent{} = me, ref, attrs \\ %{}) do
    with {:ok, number} <- entry_number(ref),
         :ok <- check_reason(attrs["reason"]) do
      Repo.transaction(fn ->
        entry = get_for_update!(me.session_id, number)
        ref = entry_ref(entry)

        cond do
          entry.author_agent_id != me.id ->
            Repo.rollback({:forbidden, "Only the author of #{ref} can retract it"})

          entry.status != :active ->
            Repo.rollback({:conflict, "#{ref} is already #{entry.status}", %{entry: ref}})

          true ->
            :ok
        end

        {1, [entry]} =
          Entry
          |> where(id: ^entry.id)
          |> select([k], k)
          |> Repo.update_all(set: [status: :retracted, updated_at: DateTime.utc_now()])

        Events.append!(%Session{id: me.session_id}, :knowledge_retracted,
          actor: me,
          payload:
            %{entry: ref, topic: entry.topic, by: me.name}
            |> put_present(:reason, attrs["reason"])
        )

        Repo.preload(entry, [:author_agent, :supersedes])
      end)
    end
  end

  ## Helpers

  # The entry `ref` replaces, marked `superseded` — or nil without `ref`.
  defp supersede!(_author, nil), do: nil

  defp supersede!(author, ref) do
    number =
      case entry_number(ref) do
        {:ok, number} -> number
        {:error, reason} -> Repo.rollback(reason)
      end

    entry = get_for_update!(author.session_id, number)

    if entry.status != :active do
      ref = entry_ref(entry)

      Repo.rollback(
        {:conflict, "#{ref} is #{entry.status}; supersede the active entry instead",
         %{entry: ref, status: entry.status}}
      )
    end

    Entry
    |> where(id: ^entry.id)
    |> Repo.update_all(set: [status: :superseded, updated_at: DateTime.utc_now()])

    %{entry | status: :superseded}
  end

  # Locks the row the way `C3.Threads` does (an `UPDATE` that bumps `updated_at`), so two
  # writers of the same entry are serialized on Postgres too.
  defp get_for_update!(session_id, number) do
    Entry
    |> where(session_id: ^session_id, number: ^number)
    |> select([k], k)
    |> Repo.update_all(set: [updated_at: DateTime.utc_now()])
    |> case do
      {1, [entry]} -> entry
      {0, _} -> Repo.rollback(:knowledge_not_found)
    end
  end

  defp next_number!(session_id) do
    {1, [next]} =
      Session
      |> where(id: ^session_id)
      |> select([s], s.next_knowledge_number)
      |> Repo.update_all(inc: [next_knowledge_number: 1])

    next - 1
  end

  defp entry_number(ref) when is_integer(ref) and ref > 0, do: {:ok, ref}

  defp entry_number(ref) do
    case parse_entry_ref(ref) do
      {:ok, number} -> {:ok, number}
      :error -> {:error, {:invalid, "#{inspect(ref)} is not an entry id like K3", %{entry: ref}}}
    end
  end

  defp check_string(attrs, key) do
    case attrs[key] do
      nil -> :ok
      value when is_binary(value) -> :ok
      _ -> {:error, {:invalid, "#{key} must be a string", %{key => ["must be a string"]}}}
    end
  end

  defp check_summary_size(summary) when is_binary(summary) do
    max = Entry.max_summary_bytes()

    if byte_size(summary) > max,
      do:
        {:error,
         {:too_large, "The summary is over #{max} bytes; record a summary, not a document"}},
      else: :ok
  end

  defp check_summary_size(_summary), do: :ok

  defp check_reason(nil), do: :ok

  defp check_reason(reason) when is_binary(reason) do
    if byte_size(reason) > Entry.max_summary_bytes(),
      do: {:error, {:too_large, "The reason is over #{Entry.max_summary_bytes()} bytes"}},
      else: :ok
  end

  defp check_reason(_reason),
    do: {:error, {:invalid, "reason must be a string", %{reason: ["must be a string"]}}}

  defp topic_param(nil), do: {:ok, nil}

  defp topic_param(topic) when is_binary(topic) do
    if topic =~ Entry.topic_format(),
      do: {:ok, topic},
      else: {:error, {:invalid, "topic is not a valid topic", %{topic: [inspect(topic)]}}}
  end

  defp topic_param(topic),
    do: {:error, {:invalid, "topic must be a string", %{topic: [inspect(topic)]}}}

  defp kind_param(nil), do: {:ok, nil}

  defp kind_param(kind) do
    if kind in Entry.kinds(),
      do: {:ok, String.to_existing_atom(kind)},
      else:
        {:error,
         {:invalid, "kind must be one of #{Enum.join(Entry.kinds(), ", ")}",
          %{kind: [inspect(kind)]}}}
  end

  defp status_param(nil), do: {:ok, @statuses["active"]}

  defp status_param(status) do
    case Map.fetch(@statuses, status) do
      {:ok, statuses} ->
        {:ok, statuses}

      :error ->
        {:error,
         {:invalid, "status must be one of active, superseded, retracted, all",
          %{status: [inspect(status)]}}}
    end
  end

  defp limit_param(nil), do: {:ok, @default_limit}
  defp limit_param(limit) when is_integer(limit), do: check_limit(limit)

  defp limit_param(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} -> check_limit(n)
      _ -> check_limit(0)
    end
  end

  defp limit_param(_limit), do: check_limit(0)

  defp check_limit(n) when n in 1..@max_limit, do: {:ok, n}

  defp check_limit(_n),
    do:
      {:error,
       {:invalid, "limit must be between 1 and #{@max_limit}", %{limit: ["out of range"]}}}

  # The topic itself and the ones under it. The topic format has no `%`, but it allows `_`,
  # which is a LIKE wildcard, so it is escaped.
  defp filter_topic(query, nil), do: query

  defp filter_topic(query, topic) do
    prefix = String.replace(topic, "_", "\\_") <> ".%"
    where(query, [k], k.topic == ^topic or fragment("? LIKE ? ESCAPE '\\'", k.topic, ^prefix))
  end

  defp source_param(nil), do: {:ok, nil}

  defp source_param(source) when is_binary(source) do
    if source =~ Entry.source_format(),
      do: {:ok, source},
      else:
        {:error,
         {:invalid, "source must be a thread or message id (T3, T3.4)",
          %{source: [inspect(source)]}}}
  end

  defp source_param(source),
    do: {:error, {:invalid, "source must be a string", %{source: [inspect(source)]}}}

  # A thread matches its own entries and its messages'; the format has no LIKE wildcards.
  defp filter_source(query, nil), do: query

  defp filter_source(query, source) do
    if String.contains?(source, "."),
      do: where(query, [k], k.source == ^source),
      else: where(query, [k], k.source == ^source or like(k.source, ^"#{source}.%"))
  end

  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind), do: where(query, [k], k.kind == ^kind)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
