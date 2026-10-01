defmodule C3.Threads.Message do
  @moduledoc """
  An entry of a thread, `T<thread>.<number>`. A `request` goes to exactly one target and
  carries its own `request_state`. The body is append-only; only the `request_*`,
  `claimed_*` and `resolved_at` columns change. See `schema.md` §4.
  """
  use C3.Schema

  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.Thread

  @default_max_body_bytes 65_536

  schema "messages" do
    field :number, :integer
    field :kind, Ecto.Enum, values: [:request, :response, :note, :system]
    field :body, :string
    field :to_target, Ecto.Enum, values: [:agent, :label, :any]
    field :to_label, :string
    field :request_state, Ecto.Enum, values: [:open, :claimed, :done, :cancelled]
    field :claimed_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec

    belongs_to :thread, Thread
    belongs_to :session, Session
    belongs_to :author_agent, Agent
    belongs_to :to_agent, Agent
    belongs_to :reply_to_message, __MODULE__
    belongs_to :claimed_by_agent, Agent

    timestamps(updated_at: false)
  end

  @fields ~w(number kind body to_target to_label request_state claimed_at resolved_at)a

  @doc "The maximum body size in bytes (`:max_body_bytes` in the `:c3` app env, 64 KB by default)."
  def max_body_bytes, do: Application.get_env(:c3, :max_body_bytes, @default_max_body_bytes)

  def changeset(message, attrs) do
    message
    |> cast(attrs, @fields)
    |> validate_required([:number, :kind, :body])
    |> validate_number(:number, greater_than_or_equal_to: 1)
    |> validate_length(:body, min: 1, max: max_body_bytes(), count: :bytes)
    |> validate_format(:to_label, Agent.label_format())
    |> validate_present_iff(:author_agent_id, &(kind(&1) != :system), "unless kind is system")
    |> validate_present_iff(:to_target, &(kind(&1) == :request), "exactly for requests")
    |> validate_present_iff(:request_state, &(kind(&1) == :request), "exactly for requests")
    |> validate_present_iff(:to_agent_id, &(get_field(&1, :to_target) == :agent), "for to=agent")
    |> validate_present_iff(:to_label, &(get_field(&1, :to_target) == :label), "for to=label")
    |> validate_claimed_by()
    |> unique_constraint([:thread_id, :number])
    |> foreign_key_constraint(:thread_id)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:author_agent_id)
    |> foreign_key_constraint(:to_agent_id)
    |> foreign_key_constraint(:reply_to_message_id)
    |> foreign_key_constraint(:claimed_by_agent_id)
    |> check_constraint(:kind, name: :messages_kind_check)
    |> check_constraint(:author_agent_id, name: :messages_author_check)
    |> check_constraint(:to_target, name: :messages_to_target_check)
    |> check_constraint(:to_agent_id, name: :messages_to_agent_check)
    |> check_constraint(:to_label, name: :messages_to_label_check)
    |> check_constraint(:request_state, name: :messages_request_state_check)
    |> check_constraint(:claimed_by_agent_id, name: :messages_claimed_by_check)
  end

  defp kind(changeset), do: get_field(changeset, :kind)

  # claimed => set; done => either (it may or may not have gone through a claim); else blank.
  defp validate_claimed_by(changeset) do
    case get_field(changeset, :request_state) do
      :done ->
        changeset

      state ->
        validate_present_iff(
          changeset,
          :claimed_by_agent_id,
          fn _ -> state == :claimed end,
          "exactly when claimed"
        )
    end
  end
end
