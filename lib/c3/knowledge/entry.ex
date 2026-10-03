defmodule C3.Knowledge.Entry do
  @moduledoc """
  An entry of a session's shared memory, `K<number>`: a decision, fact, constraint or todo
  under a short `topic`. It is never edited: a newer entry `supersedes` it, or its author
  retracts it. See `schema.md` §8.
  """
  use C3.Schema

  alias C3.Sessions.{Agent, Session}

  @kinds [:decision, :fact, :constraint, :todo]
  @topic_format ~r/^[a-z0-9][a-z0-9_-]*(\.[a-z0-9][a-z0-9_-]*)*$/
  @source_format ~r/^T[1-9][0-9]{0,9}(\.[1-9][0-9]{0,9})?$/

  schema "knowledge" do
    field :number, :integer
    field :topic, :string
    field :kind, Ecto.Enum, values: @kinds
    field :summary, :string
    field :source, :string
    field :status, Ecto.Enum, values: [:active, :superseded, :retracted], default: :active

    belongs_to :session, Session
    belongs_to :author_agent, Agent
    belongs_to :supersedes, __MODULE__

    timestamps()
  end

  @fields ~w(number topic kind summary source)a

  @doc "The kinds of entry, as strings."
  def kinds, do: Enum.map(@kinds, &Atom.to_string/1)

  @doc "A topic: lowercase words of `a-z 0-9 _ -`, joined by dots (`auth`, `db.schema`)."
  def topic_format, do: @topic_format

  @doc "A source: a thread or message id (`T3`, `T3.4`)."
  def source_format, do: @source_format

  @doc "The maximum summary size in bytes (`C3.Config`, `:knowledge_summary_max_bytes`)."
  def max_summary_bytes, do: C3.Config.get(:knowledge_summary_max_bytes)

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @fields)
    |> validate_required([:number, :topic, :kind, :summary])
    |> validate_number(:number, greater_than_or_equal_to: 1)
    |> validate_length(:topic, max: 64)
    |> validate_format(:topic, @topic_format,
      message: "must be lowercase words of a-z, 0-9, _ or -, joined by dots"
    )
    |> validate_length(:summary, min: 1, max: max_summary_bytes(), count: :bytes)
    |> validate_format(:source, @source_format,
      message: "must be a thread or message id (T3, T3.4)"
    )
    |> unique_constraint([:session_id, :number])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:author_agent_id)
    |> foreign_key_constraint(:supersedes_id)
    |> check_constraint(:kind, name: :knowledge_kind_check)
    |> check_constraint(:status, name: :knowledge_status_check)
  end
end
