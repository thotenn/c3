defmodule C3Web.V1.InboxController do
  @moduledoc """
  `GET /v1/inbox`, the watcher's central call (spec, *API › Watcher*): the requests the agent
  has to do, the cancellations of requests it was on (stop working on those), and the
  security alerts it has not seen. `empty: true` means nothing to do. Reading it marks the
  cancellations and alerts seen, so each one shows once.
  """
  use C3Web, :controller

  alias C3.{Sessions, Threads}

  def show(conn, _params) do
    agent = conn.assigns.current_agent
    threads = Threads.inbox(agent)

    {cancelled, alerts} =
      agent |> Sessions.take_notices() |> Enum.split_with(&(&1.type == :request_cancelled))

    render(conn, :show,
      you: agent,
      threads:
        Enum.map(threads, fn {thread, requests} -> {thread, Threads.state(thread), requests} end),
      cancelled: cancelled,
      alerts: alerts
    )
  end
end
