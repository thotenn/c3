defmodule C3.Sessions.IdempotencyKey do
  @moduledoc """
  The stored response of an agent's write, so a retry with the same `Idempotency-Key` does
  not duplicate it. See `schema.md` §8.
  """
  use C3.Schema

  alias C3.Sessions.Agent

  schema "idempotency_keys" do
    field :key, :string
    field :request_hash, :string
    field :response_status, :integer
    field :response_body, :map

    belongs_to :agent, Agent

    timestamps(updated_at: false)
  end

  @fields ~w(key request_hash response_status response_body)a

  def changeset(idempotency_key, attrs) do
    idempotency_key
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_length(:key, min: 1, max: 100)
    |> validate_number(:response_status, greater_than_or_equal_to: 100, less_than: 600)
    |> unique_constraint([:agent_id, :key])
    |> foreign_key_constraint(:agent_id)
  end
end
