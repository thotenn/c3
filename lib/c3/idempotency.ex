defmodule C3.Idempotency do
  @moduledoc """
  `Idempotency-Key` for the agents' writes (`schema.md` §8): the first response to a key is
  stored, and a retry with the same key and the same request gets it back instead of running
  again. The same key with another request is refused.

  The stored row only exists once the first request finished, so two copies of the same
  request in flight at once would both run. An in-flight mark in ETS (`begin/2`) closes that
  gap on this node: the second copy gets a `409` until the first one is done. A mark whose
  request died without finishing goes stale after `@stale_ms` and is taken over.
  """
  use GenServer

  import Ecto.Query

  alias C3.Repo
  alias C3.Sessions.{Agent, IdempotencyKey}

  @table __MODULE__
  @stale_ms 60_000
  @ttl_seconds 24 * 3600

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The stored response of the agent for `key`, or `nil`."
  def lookup(%Agent{} = agent, key), do: C3.Sessions.get_idempotency_key(agent, key)

  @doc "Marks `key` of the agent in flight: `:ok`, or `:busy` if another copy is running."
  def begin(%Agent{id: agent_id}, key) do
    now = System.monotonic_time(:millisecond)
    mark = {{agent_id, key}, now}

    cond do
      :ets.insert_new(@table, mark) ->
        :ok

      match?([{_, at}] when now - at > @stale_ms, :ets.lookup(@table, {agent_id, key})) ->
        :ets.insert(@table, mark)
        :ok

      true ->
        :busy
    end
  end

  @doc "Clears the in-flight mark."
  def finish(%Agent{id: agent_id}, key), do: :ets.delete(@table, {agent_id, key})

  @doc "Stores the response of the first request with `key`. A concurrent duplicate is ignored."
  def store(%Agent{id: agent_id}, key, request_hash, status, body) do
    %IdempotencyKey{agent_id: agent_id}
    |> IdempotencyKey.changeset(%{
      key: key,
      request_hash: request_hash,
      response_status: status,
      response_body: body
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:agent_id, :key])
  end

  @doc "Deletes the keys older than a day. Returns how many."
  def purge(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@ttl_seconds, :second)
    {count, _} = IdempotencyKey |> where([k], k.inserted_at < ^cutoff) |> Repo.delete_all()
    count
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
