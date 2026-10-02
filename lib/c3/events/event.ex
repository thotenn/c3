defmodule C3.Events.Event do
  @moduledoc """
  One entry of a session's append-only event log, what the watcher consumes. `seq` grows
  without gaps per session. See `schema.md` §5.
  """
  use C3.Schema

  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.{Message, Thread}

  @types [
    agent_joined: "agent.joined",
    agent_left: "agent.left",
    agent_revoked: "agent.revoked",
    thread_opened: "thread.opened",
    message_posted: "message.posted",
    thread_status_changed: "thread.status_changed",
    request_claimed: "request.claimed",
    request_claim_expired: "request.claim_expired",
    request_cancelled: "request.cancelled",
    security_join_failed: "security.join_failed",
    session_joins_locked: "session.joins_locked",
    session_joins_unlocked: "session.joins_unlocked",
    session_secret_rotated: "session.secret_rotated",
    session_closing_soon: "session.closing_soon",
    session_closed: "session.closed"
  ]

  schema "events" do
    field :seq, :integer
    field :type, Ecto.Enum, values: @types
    field :payload, :map, default: %{}

    belongs_to :session, Session
    belongs_to :actor_agent, Agent
    belongs_to :thread, Thread
    belongs_to :message, Message

    timestamps(updated_at: false)
  end

  @fields ~w(seq type payload)a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required([:seq, :type, :payload])
    |> validate_number(:seq, greater_than_or_equal_to: 1)
    |> unique_constraint([:session_id, :seq])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:actor_agent_id)
    |> foreign_key_constraint(:thread_id)
    |> foreign_key_constraint(:message_id)
    |> check_constraint(:type, name: :events_type_check)
  end
end
