defmodule C3.Threads.MessageAck do
  @moduledoc """
  One recipient of a message that asked for an acknowledgement (`ack_required`): pending while
  `acked_at` is nil. Acknowledging is not answering: a request stays open. See `schema.md` §4.
  """
  use C3.Schema

  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.Message

  schema "message_acks" do
    field :acked_at, :utc_datetime_usec

    belongs_to :message, Message
    belongs_to :session, Session
    belongs_to :agent, Agent

    timestamps(updated_at: false)
  end
end
