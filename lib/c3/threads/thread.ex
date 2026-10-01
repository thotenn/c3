defmodule C3.Threads.Thread do
  @moduledoc """
  A thread of a session, `T<number>`. `status` is a cache of the state derived from the
  thread's requests: only the session server writes it. See `schema.md` §3.
  """
  use C3.Schema

  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.Message

  schema "threads" do
    field :number, :integer
    field :title, :string

    field :status, Ecto.Enum,
      values: [:pending, :processing, :answered, :finished],
      default: :pending

    field :finished_at, :utc_datetime_usec
    field :last_message_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
    field :lock_version, :integer, default: 1

    belongs_to :session, Session
    belongs_to :opened_by_agent, Agent
    has_many :messages, Message

    timestamps()
  end

  @fields ~w(number title status finished_at last_message_at)a

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, @fields)
    |> validate_required([:number, :title])
    |> validate_number(:number, greater_than_or_equal_to: 1)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_present_iff(:finished_at, &(get_field(&1, :status) == :finished), "when finished")
    |> unique_constraint([:session_id, :number])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:opened_by_agent_id)
    |> check_constraint(:status, name: :threads_status_check)
    |> check_constraint(:finished_at, name: :threads_finished_at_check)
  end
end
