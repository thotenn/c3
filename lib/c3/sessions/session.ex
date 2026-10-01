defmodule C3.Sessions.Session do
  @moduledoc "A work session. `closed` is terminal. See `schema.md` §1."
  use C3.Schema

  alias C3.Sessions.Agent
  alias C3.Threads.Thread

  schema "sessions" do
    field :code, :string
    field :secret_hash, :string, redact: true
    field :label, :string
    field :status, Ecto.Enum, values: [:open, :closed], default: :open
    field :joins_locked_at, :utc_datetime_usec
    field :next_agent_number, :integer, default: 1
    field :next_thread_number, :integer, default: 1
    field :event_seq, :integer, default: 0
    field :last_activity_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
    field :expires_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :closed_by, :string
    field :close_reason, Ecto.Enum, values: [:manual, :idle, :max_ttl, :admin]

    has_many :agents, Agent
    has_many :threads, Thread

    timestamps()
  end

  @fields ~w(code secret_hash label status joins_locked_at next_agent_number next_thread_number
             event_seq last_activity_at expires_at closed_at closed_by close_reason)a

  def changeset(session, attrs) do
    session
    |> cast(attrs, @fields)
    |> validate_required([:code, :secret_hash, :expires_at])
    |> validate_length(:label, max: 200)
    |> validate_number(:next_agent_number, greater_than_or_equal_to: 1)
    |> validate_number(:next_thread_number, greater_than_or_equal_to: 1)
    |> validate_number(:event_seq, greater_than_or_equal_to: 0)
    |> validate_format(:closed_by, ~r/^(AG[1-9][0-9]*|system|admin)$/)
    |> validate_present_iff(:closed_at, &(get_field(&1, :status) == :closed), "when closed")
    |> unique_constraint(:code)
    |> check_constraint(:status, name: :sessions_status_check)
    |> check_constraint(:closed_at, name: :sessions_closed_at_check)
    |> check_constraint(:close_reason, name: :sessions_close_reason_check)
  end
end
