defmodule C3.Sessions do
  @moduledoc """
  Sessions, their agents and the agents' idempotency keys.

  Read-only for now: creating, joining, leaving and closing land in F2, where every write
  of a session goes through its session server.
  """
  import Ecto.Query

  alias C3.Repo
  alias C3.Sessions.{Agent, IdempotencyKey, Session}

  @doc "The session with the public `code`, or `nil`."
  def get_session_by_code(code) when is_binary(code), do: Repo.get_by(Session, code: code)

  @doc "The agent whose token hashes to `token_hash`, with its session preloaded, or `nil`."
  def get_agent_by_token_hash(token_hash) when is_binary(token_hash) do
    Agent
    |> where(token_hash: ^token_hash)
    |> preload(:session)
    |> Repo.one()
  end

  @doc "The agents of a session, in join order."
  def list_agents(%Session{id: session_id}) do
    Agent
    |> where(session_id: ^session_id)
    |> order_by(:number)
    |> Repo.all()
  end

  @doc "The stored response for `key` of an agent, or `nil`."
  def get_idempotency_key(%Agent{id: agent_id}, key) when is_binary(key) do
    Repo.get_by(IdempotencyKey, agent_id: agent_id, key: key)
  end
end
