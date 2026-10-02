defmodule C3Web.V1.EventController do
  @moduledoc """
  The watcher's feed (spec, *API › Watcher*):

    * `GET /sessions/:code/events?after=<seq>&wait=<s>` — the long-poll. The events with
      `seq > after` (at most `limit`, default and cap 100); if there are none, the request
      is held until one is committed or `wait` seconds pass (capped at
      `long_poll_max_wait`), and then answers `events: []`. `last_seq` is the cursor for the
      next poll either way.
    * `GET /sessions/:code/events/stream` — SSE: every event as `id: <seq>`, `event: <type>`,
      `data: <json>`, resuming after `Last-Event-ID` (or `?after=`), with a `: keepalive`
      comment every `sse_keepalive` seconds. Ends after `session.closed`, when the agent
      leaves, or when the client goes away.
    * `GET /sessions/:code/watch?after=<seq>&wait=<s>` — the long-poll of the watcher
      script, in `text/plain`: a `cursor <seq>` line and one line per event that concerns
      the caller (`C3.Watch`). Irrelevant events advance the cursor without answering, so
      the request is held until something concerns the agent or `wait` passes.
    * `POST /heartbeat` — an explicit sign of life; any request already is one.

  None of them counts as activity on the session (see `C3Web.Plugs.AgentAuth`).
  """
  use C3Web, :controller

  alias C3.{Events, Repo, Sessions, Watch}
  alias C3Web.V1.EventJSON

  action_fallback C3Web.V1.FallbackController

  @max_limit 100

  def index(conn, params) do
    with {:ok, after_seq} <- int_param(params, "after", 0),
         {:ok, wait} <- int_param(params, "wait", 0),
         {:ok, limit} <- int_param(params, "limit", @max_limit) do
      session = conn.assigns.current_session
      wait_ms = min(wait, C3.Config.get(:long_poll_max_wait)) * 1000

      events =
        Events.wait_after(session, after_seq, wait_ms, limit: min(max(limit, 1), @max_limit))

      render(conn, :index, events: events, after: after_seq)
    end
  end

  def watch(conn, params) do
    with {:ok, after_seq} <- int_param(params, "after", 0),
         {:ok, wait} <- int_param(params, "wait", 0) do
      %{current_session: session, current_agent: agent} = conn.assigns
      deadline = now_ms() + min(wait, C3.Config.get(:long_poll_max_wait)) * 1000
      {cursor, lines} = watch_after(session, agent, after_seq, deadline)

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, Enum.map(["cursor #{cursor}" | lines], &[&1, "\n"]))
    end
  end

  # Polls again with the new cursor while the events that come are someone else's.
  defp watch_after(session, agent, cursor, deadline) do
    remaining = max(deadline - now_ms(), 0)

    case Events.wait_after(session, cursor, remaining, limit: @max_limit) do
      [] ->
        {cursor, []}

      events ->
        cursor = List.last(events).seq

        case Enum.flat_map(events, &List.wrap(Watch.line(&1, agent))) do
          [] when remaining > 0 -> watch_after(session, agent, cursor, deadline)
          lines -> {cursor, lines}
        end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  def heartbeat(conn, _params) do
    agent = conn.assigns.current_agent
    json(conn, %{ok: true, you: agent.name, last_seen_at: agent.last_seen_at})
  end

  def stream(conn, params) do
    with {:ok, after_seq} <- last_event_id(conn, params) do
      %{current_session: session, current_agent: agent} = conn.assigns

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        # Asks a buffering reverse proxy to pass the events through as they come.
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      :ok = Events.subscribe(session)

      try do
        case chunk(conn, "retry: 3000\n\n") do
          {:ok, conn} -> deliver(conn, session, agent, after_seq)
          {:error, _} -> conn
        end
      after
        Events.unsubscribe(session)
      end
    end
  end

  # Subscribed before the first query, like the long-poll: nothing slips in between.
  defp deliver(conn, session, agent, cursor) do
    case Events.list_after(session, cursor) do
      [] ->
        listen(conn, session, agent, cursor)

      events ->
        with {:ok, conn} <- chunk(conn, Enum.map(events, &sse_event/1)) do
          if Enum.any?(events, &ends_stream?(&1, agent)),
            do: conn,
            else: deliver(conn, session, agent, List.last(events).seq)
        else
          {:error, _} -> conn
        end
    end
  end

  defp listen(conn, %{id: session_id} = session, agent, cursor) do
    receive do
      {:c3_events, ^session_id, seq} when seq > cursor ->
        deliver(conn, session, agent, cursor)

      {:c3_events, ^session_id, _seq} ->
        listen(conn, session, agent, cursor)
    after
      C3.Config.get(:sse_keepalive) * 1000 ->
        with %Sessions.Agent{status: :active} = agent <- Repo.reload(agent),
             {:ok, conn} <- chunk(conn, ": keepalive\n\n") do
          listen(conn, session, Sessions.touch_seen(agent), cursor)
        else
          _ -> conn
        end
    end
  end

  defp sse_event(event) do
    data = event |> EventJSON.event() |> Jason.encode!()

    [
      "id: ",
      Integer.to_string(event.seq),
      "\nevent: ",
      EventJSON.type(event),
      "\ndata: ",
      data,
      "\n\n"
    ]
  end

  defp ends_stream?(%{type: :session_closed}, _agent), do: true
  defp ends_stream?(%{type: :agent_left, actor_agent_id: id}, %{id: id}), do: true
  defp ends_stream?(_event, _agent), do: false

  defp last_event_id(conn, params) do
    case get_req_header(conn, "last-event-id") do
      [id | _] -> parse_int("Last-Event-ID", String.trim(id))
      [] -> int_param(params, "after", 0)
    end
  end

  defp int_param(params, key, default) do
    case params[key] do
      nil -> {:ok, default}
      value -> parse_int(key, value)
    end
  end

  defp parse_int(key, value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid, "#{key} must be a non-negative integer", %{key => value}}}
    end
  end
end
