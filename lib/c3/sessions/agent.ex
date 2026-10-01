defmodule C3.Sessions.Agent do
  @moduledoc """
  A participant of a session, named `AG<number>` by C3. Never deleted on its own: leaving
  sets `status` to `left`. See `schema.md` §2.
  """
  use C3.Schema

  alias C3.Sessions.Session

  @label_format ~r/^[a-z0-9][a-z0-9-]{0,39}$/

  schema "agents" do
    field :number, :integer
    field :name, :string
    field :label, :string
    field :token_hash, :string, redact: true
    field :status, Ecto.Enum, values: [:active, :left, :revoked], default: :active
    field :alerts_seen_seq, :integer, default: 0
    field :joined_ip, :string
    field :user_agent, :string
    field :last_seen_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
    field :left_at, :utc_datetime_usec

    belongs_to :session, Session

    timestamps()
  end

  @fields ~w(number name label token_hash status alerts_seen_seq joined_ip user_agent
             last_seen_at left_at)a

  @doc "The format an agent label (and a `label:` target) must have."
  def label_format, do: @label_format

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, @fields)
    |> validate_required([:number, :name, :token_hash, :joined_ip])
    |> validate_number(:number, greater_than_or_equal_to: 1)
    |> validate_name()
    |> validate_format(:label, @label_format)
    |> validate_number(:alerts_seen_seq, greater_than_or_equal_to: 0)
    |> validate_present_iff(:left_at, &(get_field(&1, :status) != :active), "once not active")
    |> unique_constraint([:session_id, :number])
    |> unique_constraint([:session_id, :name])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:session_id)
    |> check_constraint(:status, name: :agents_status_check)
  end

  defp validate_name(changeset) do
    number = get_field(changeset, :number)

    if is_integer(number) and get_field(changeset, :name) != "AG#{number}" do
      add_error(changeset, :name, "must be AG followed by the agent number")
    else
      changeset
    end
  end
end
