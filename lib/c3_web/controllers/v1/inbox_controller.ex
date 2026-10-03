defmodule C3Web.V1.InboxController do
  @moduledoc """
  `GET /v1/inbox`, the watcher's central call (spec, *API › Watcher*): the requests the agent
  has to do — the threads with the most urgent ones first —, the messages it still has to
  acknowledge, the cancellations of requests it was on (stop working on those), and the
  security alerts it has not seen. `empty: true` means nothing to do. Reading it marks the
  cancellations and alerts seen, so each one shows once.
  """
  use C3Web, :controller

  alias C3.{Sessions, Threads}
  alias C3.Threads.Acks

  def show(conn, _params) do
    render(conn, :show, inbox(conn.assigns.current_agent))
  end

  @doc "What the inbox of `agent` renders; reading it marks its notices seen."
  def inbox(agent) do
    threads =
      agent
      |> Threads.inbox()
      |> Enum.sort_by(fn {thread, requests} ->
        {-(requests |> Enum.map(&Acks.rank(&1.importance)) |> Enum.max()), thread.number}
      end)

    request_ids = for {_thread, requests} <- threads, request <- requests, do: request.id

    {cancelled, alerts} =
      agent |> Sessions.take_notices() |> Enum.split_with(&(&1.type == :request_cancelled))

    %{
      you: agent,
      threads:
        Enum.map(threads, fn {thread, requests} -> {thread, Threads.state(thread), requests} end),
      to_ack: Acks.pending(agent, request_ids),
      cancelled: cancelled,
      alerts: alerts
    }
  end
end
