defmodule C3.Security.JoinFailure do
  @moduledoc """
  A failed attempt to join a session; thresholds and bans are computed from these rows.
  Survives the session's purge with `session_id` set to `NULL`. See `schema.md` §6.
  """
  use C3.Schema

  alias C3.Sessions.Session

  schema "join_failures" do
    field :ip, :string
    field :ip_full, :string

    field :reason, Ecto.Enum,
      values: [:invalid_secret, :unknown_code, :session_closed, :joins_locked]

    field :attempted_code, :string
    field :attempted_label, :string
    field :user_agent, :string

    belongs_to :session, Session

    timestamps(updated_at: false)
  end

  @fields ~w(ip ip_full reason attempted_code attempted_label user_agent)a

  def changeset(join_failure, attrs) do
    join_failure
    |> cast(attrs, @fields)
    |> validate_required([:ip, :reason, :attempted_code])
    |> validate_length(:attempted_code, max: 32)
    |> foreign_key_constraint(:session_id)
    |> check_constraint(:reason, name: :join_failures_reason_check)
  end
end
