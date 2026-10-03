defmodule C3.Reservations.Reservation do
  @moduledoc """
  An advisory reservation of a session, `R<number>`: an agent holds `pattern` (an opaque
  `<namespace>:<rest>` glob such as `repo:c3/lib/**` or `slot:deploy`) until it releases it or
  `expires_at` passes. `waiters` are the agents that ran into it, told when it frees up. See
  `schema.md` §9.
  """
  use C3.Schema

  alias C3.Sessions.{Agent, Session}

  @release_reasons [:released, :expired, :left, :revoked, :session_closed]
  @pattern_format ~r/^[a-z][a-z0-9_-]*:[^\s[:cntrl:]]+$/u

  schema "reservations" do
    field :number, :integer
    field :pattern, :string
    field :exclusive, :boolean, default: true
    field :reason, :string
    field :expires_at, :utc_datetime_usec
    field :released_at, :utc_datetime_usec
    field :release_reason, Ecto.Enum, values: @release_reasons
    field :waiters, {:array, :string}, default: []

    belongs_to :session, Session
    belongs_to :agent, Agent

    timestamps()
  end

  @fields ~w(number pattern exclusive reason expires_at)a

  @doc "A pattern: `<namespace>:<rest>`, the namespace in `a-z 0-9 _ -`, no spaces."
  def pattern_format, do: @pattern_format

  def changeset(reservation, attrs) do
    reservation
    |> cast(attrs, @fields)
    |> validate_required([:number, :pattern, :exclusive, :expires_at])
    |> validate_number(:number, greater_than_or_equal_to: 1)
    |> validate_length(:pattern, max: 256, count: :bytes)
    |> validate_format(:pattern, @pattern_format,
      message: "must be <namespace>:<glob>, e.g. repo:c3/lib/** or slot:deploy"
    )
    |> validate_length(:reason, max: 500, count: :bytes)
    |> unique_constraint([:session_id, :number])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:agent_id)
    |> check_constraint(:release_reason, name: :reservations_release_reason_check)
  end
end
