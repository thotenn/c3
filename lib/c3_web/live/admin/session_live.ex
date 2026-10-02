defmodule C3Web.Admin.SessionLive do
  @moduledoc """
  One session, live: its agents, its threads with their derived state, the messages of the
  thread picked (`/threads/:number`), and the event log, newest first. The actions: close
  the session, revoke an agent, purge a closed session.

  Live like the watcher: subscribed (to the `admin` topic) *before* the first read, an
  announcement `{:c3_events, id, seq}` past the last `seq` shown is one `list_after/3` for
  every event since. Those events go to the log as they are, and their types say what else
  is stale (agents, threads, the session, the open thread); that is reloaded once per
  `@debounce_ms`, however many events came. A slow tick reloads agents and session, for
  `last_seen_at` and `last_activity_at`, which move without an event.
  """
  use C3Web, :live_view

  import C3Web.Admin.Components

  alias C3.{Admin, Events, Sessions}
  alias C3.Threads.Targets

  @page 100
  @debounce_ms 300
  @tick_ms 30_000

  @agent_types ~w(agent_joined agent_left agent_revoked session_closed)a
  @thread_types ~w(thread_opened message_posted thread_status_changed request_claimed
                   request_claim_expired request_cancelled agent_left agent_revoked)a

  @impl true
  def mount(%{"code" => code}, _session, socket) do
    if connected?(socket), do: Events.subscribe_admin()

    case Admin.get_session(code) do
      nil ->
        {:ok, socket |> put_flash(:error, "No session #{code}.") |> push_navigate(to: ~p"/admin")}

      session ->
        if connected?(socket), do: :timer.send_interval(@tick_ms, :tick)
        events = Events.list_recent(session, @page)

        {:ok,
         socket
         |> assign(
           session: session,
           page_title: session.code,
           selected: nil,
           stale: MapSet.new(),
           reload_scheduled?: false,
           last_seq: last_seq(events),
           oldest_seq: oldest_seq(events),
           more_events?: length(events) == @page
         )
         |> stream_configure(:threads, dom_id: &"thread-#{&1.thread.id}")
         |> stream(:events, events)
         |> stream(:messages, [])
         |> load_agents()
         |> load_threads()}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) when not is_map_key(socket.assigns, :session),
    do: {:noreply, socket}

  def handle_params(%{"number" => number}, _uri, socket) do
    with {n, ""} <- Integer.parse(number),
         {thread, messages} <- Admin.get_thread(socket.assigns.session, n) do
      {:noreply,
       socket
       |> assign(selected: thread)
       |> stream(:messages, messages, reset: true)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "No thread T#{number}.")
         |> push_patch(to: ~p"/admin/sessions/#{socket.assigns.session.code}")}
    end
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, socket |> assign(selected: nil) |> stream(:messages, [], reset: true)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} admin wide>
      <section id="session-header" class="flex flex-wrap items-start justify-between gap-4">
        <div class="space-y-1">
          <div class="flex items-center gap-3">
            <h1 class="font-mono text-2xl font-semibold tracking-tight">{@session.code}</h1>
            <.session_status session={@session} />
            <span
              id="live-indicator"
              class="inline-flex items-center gap-1 text-xs text-base-content/60"
            >
              <span class="size-2 rounded-full bg-success motion-safe:animate-pulse"></span> live
            </span>
          </div>
          <p :if={@session.label} class="text-base-content/80">{@session.label}</p>
          <dl class="flex flex-wrap gap-x-6 gap-y-1 text-xs text-base-content/60">
            <div>created <.time at={@session.inserted_at} /></div>
            <div>last activity <.time at={@session.last_activity_at} /></div>
            <div :if={@session.status == :open}>expires <.time at={@session.expires_at} /></div>
            <div :if={@session.closed_at}>
              closed <.time at={@session.closed_at} /> by {@session.closed_by}
            </div>
            <div>{@session.event_seq} events</div>
          </dl>
        </div>
        <div class="flex gap-2">
          <button
            :if={@session.status == :open && @session.joins_locked_at}
            id="unlock-joins"
            phx-click="unlock_joins"
            data-confirm="Let new agents join this session again?"
            class="rounded-md border border-warning/50 px-3 py-1.5 text-sm text-warning hover:bg-warning/10 transition-colors"
          >
            Unlock joins
          </button>
          <button
            :if={@session.status == :open}
            id="close-session"
            phx-click="close_session"
            data-confirm="Close this session for every agent? This cannot be undone."
            class="rounded-md border border-error/40 px-3 py-1.5 text-sm text-error hover:bg-error/10 transition-colors"
          >
            Close session
          </button>
          <button
            :if={@session.status == :closed}
            id="purge-session"
            phx-click="purge_session"
            data-confirm="Delete this session and everything in it now? This cannot be undone."
            class="rounded-md border border-error/40 px-3 py-1.5 text-sm text-error hover:bg-error/10 transition-colors"
          >
            Purge now
          </button>
        </div>
      </section>

      <section>
        <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide text-base-content/60">
          Agents
        </h2>
        <div class="overflow-x-auto rounded-lg border border-base-300">
          <table class="w-full text-sm">
            <thead class="bg-base-200 text-left text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-3 py-2">Name</th>
                <th class="px-3 py-2">Label</th>
                <th class="px-3 py-2">Status</th>
                <th class="px-3 py-2">Joined from</th>
                <th class="px-3 py-2">Last seen</th>
                <th class="px-3 py-2"></th>
              </tr>
            </thead>
            <tbody id="agents" phx-update="stream">
              <tr :for={{id, agent} <- @streams.agents} id={id} class="border-t border-base-300">
                <td class="px-3 py-2 font-mono">{agent.name}</td>
                <td class="px-3 py-2">{agent.label}</td>
                <td class="px-3 py-2"><.agent_status status={agent.status} /></td>
                <td class="px-3 py-2 font-mono text-xs" title={agent.user_agent}>
                  {agent.joined_ip}
                </td>
                <td class="px-3 py-2"><.time at={agent.last_seen_at} /></td>
                <td class="px-3 py-2 text-right">
                  <button
                    :if={agent.status == :active}
                    id={"revoke-#{agent.id}"}
                    phx-click="revoke"
                    phx-value-id={agent.id}
                    data-confirm={"Revoke #{agent.name}? Its token stops working."}
                    class="rounded border border-base-300 px-2 py-1 text-xs hover:bg-base-200 transition-colors"
                  >
                    Revoke
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="grid gap-6 lg:grid-cols-3">
        <div>
          <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Threads
          </h2>
          <ul
            id="threads"
            phx-update="stream"
            class="divide-y divide-base-300 rounded-lg border border-base-300"
          >
            <li
              id="threads-empty"
              class="hidden only:block px-3 py-6 text-center text-sm text-base-content/60"
            >
              No threads yet.
            </li>
            <li :for={{id, row} <- @streams.threads} id={id}>
              <.link
                patch={~p"/admin/sessions/#{@session.code}/threads/#{row.thread.number}"}
                class={[
                  "block px-3 py-2 hover:bg-base-200/60 transition-colors",
                  @selected && @selected.id == row.thread.id && "bg-base-200"
                ]}
              >
                <div class="flex items-center justify-between gap-2">
                  <span class="font-mono text-xs text-base-content/60">T{row.thread.number}</span>
                  <.thread_status status={row.state.status} />
                </div>
                <p class="mt-1 truncate text-sm">{row.thread.title}</p>
                <p class="mt-0.5 text-xs text-base-content/60">
                  by {row.thread.opened_by_agent.name}
                  <span :if={row.state.awaiting != []}>
                    · awaiting {Enum.join(row.state.awaiting, ", ")}
                  </span>
                  <span :if={row.state.processing_by != []}>
                    · processing {Enum.join(row.state.processing_by, ", ")}
                  </span>
                </p>
              </.link>
            </li>
          </ul>
        </div>

        <div class="lg:col-span-2">
          <div class="mb-2 flex items-center justify-between gap-2">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              <%= if @selected do %>
                T{@selected.number} · {@selected.title}
              <% else %>
                Messages
              <% end %>
            </h2>
            <button
              :if={@selected && @session.status == :open && is_nil(@selected.finished_at)}
              id="finish-thread"
              phx-click="finish_thread"
              data-confirm={"Finish T#{@selected.number}? Its pending requests are cancelled."}
              class="rounded border border-base-300 px-2 py-1 text-xs hover:bg-base-200 transition-colors"
            >
              Finish thread
            </button>
          </div>
          <p
            :if={!@selected}
            id="no-thread"
            class="rounded-lg border border-dashed border-base-300 px-3 py-6 text-center text-sm text-base-content/60"
          >
            Pick a thread to read its messages.
          </p>
          <ol :if={@selected} id="messages" phx-update="stream" class="space-y-3">
            <li
              :for={{id, message} <- @streams.messages}
              id={id}
              class="rounded-lg border border-base-300 p-3"
            >
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/60">
                <span class="font-mono">T{@selected.number}.{message.number}</span>
                <span class="font-medium text-base-content">{message.kind}</span>
                <span :if={message.author_agent}>by {message.author_agent.name}</span>
                <span :if={message.kind == :request}>
                  → {Targets.display(
                    message.to_target,
                    message.to_label,
                    message.to_agent && message.to_agent.name
                  )} · {message.request_state}
                  <span :if={message.claimed_by_agent}>
                    by {message.claimed_by_agent.name}
                  </span>
                </span>
                <span :if={message.reply_to_message}>
                  re T{@selected.number}.{message.reply_to_message.number}
                </span>
                <.time at={message.inserted_at} />
              </div>
              <pre class="mt-2 whitespace-pre-wrap break-words font-sans text-sm">{message.body}</pre>
              <ul :if={message.attachments != []} class="mt-2 flex flex-wrap gap-2">
                <li :for={file <- message.attachments}>
                  <a
                    id={"attachment-#{message.id}-#{file.id}"}
                    href={~p"/admin/sessions/#{@session.code}/attachments/#{file.id}"}
                    class="inline-flex items-center gap-1 rounded border border-base-300 px-2 py-1 text-xs hover:bg-base-200 transition-colors"
                  >
                    <.icon name="hero-paper-clip" class="size-3.5" />
                    {file.filename}
                    <span class="text-base-content/50">{format_bytes(file.size_bytes)}</span>
                  </a>
                </li>
              </ul>
            </li>
          </ol>
        </div>
      </section>

      <section>
        <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide text-base-content/60">
          Event log
        </h2>
        <ol
          id="events"
          phx-update="stream"
          class="divide-y divide-base-300 rounded-lg border border-base-300 font-mono text-xs"
        >
          <li id="events-empty" class="hidden only:block px-3 py-6 text-center text-base-content/60">
            No events.
          </li>
          <li
            :for={{id, event} <- @streams.events}
            id={id}
            class="grid grid-cols-[4rem_10rem_12rem_1fr] gap-3 px-3 py-1.5"
          >
            <span class="text-right tabular-nums text-base-content/50">#{event.seq}</span>
            <span class="text-base-content/60"><.time at={event.inserted_at} /></span>
            <span class="font-medium">{event_type(event)}</span>
            <span class="break-words font-sans text-sm">{event_summary(event)}</span>
          </li>
        </ol>
        <button
          :if={@more_events?}
          id="load-older"
          phx-click="load_older"
          class="mt-2 rounded border border-base-300 px-3 py-1 text-xs hover:bg-base-200 transition-colors"
        >
          Load older events
        </button>
      </section>
    </Layouts.app>
    """
  end

  ## Actions

  @impl true
  def handle_event("close_session", _params, socket) do
    case Admin.close_session(socket.assigns.session) do
      {:ok, session} ->
        {:noreply, socket |> assign(session: session) |> put_flash(:info, "Session closed.")}

      {:error, :session_closed} ->
        {:noreply, put_flash(socket, :error, "The session was already closed.")}
    end
  end

  def handle_event("unlock_joins", _params, socket) do
    case Admin.unlock_joins(socket.assigns.session) do
      {:ok, true} ->
        session = Admin.get_session(socket.assigns.session.code)
        {:noreply, socket |> assign(session: session) |> put_flash(:info, "Joins unlocked.")}

      {:ok, false} ->
        {:noreply, put_flash(socket, :error, "Joins were not locked.")}
    end
  end

  def handle_event("finish_thread", _params, %{assigns: %{selected: %{} = thread}} = socket) do
    case Admin.finish_thread(thread) do
      {:ok, %{changed: true, cancelled: cancelled}} ->
        note = if cancelled == [], do: "", else: "; cancelled #{Enum.join(cancelled, ", ")}"

        {:noreply,
         socket
         |> assign(selected: %{thread | finished_at: DateTime.utc_now()})
         |> put_flash(:info, "T#{thread.number} finished#{note}.")}

      {:ok, %{changed: false}} ->
        {:noreply, put_flash(socket, :error, "The thread was already finished.")}
    end
  end

  def handle_event("finish_thread", _params, socket), do: {:noreply, socket}

  def handle_event("revoke", %{"id" => id}, socket) do
    agent = Enum.find(Sessions.list_agents(socket.assigns.session), &(to_string(&1.id) == id))

    case agent && Admin.revoke_agent(agent) do
      {:ok, _released} ->
        {:noreply, socket |> put_flash(:info, "#{agent.name} revoked.") |> load_agents()}

      _ ->
        {:noreply, put_flash(socket, :error, "That agent is not active.")}
    end
  end

  def handle_event("purge_session", _params, socket) do
    case Admin.purge_session(socket.assigns.session) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Session #{socket.assigns.session.code} purged.")
         |> push_navigate(to: ~p"/admin")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Only a closed session can be purged.")}
    end
  end

  def handle_event("load_older", _params, socket) do
    %{session: session, oldest_seq: oldest} = socket.assigns
    events = Events.list_recent(session, @page, oldest)

    {:noreply,
     socket
     |> stream(:events, events, at: -1)
     |> assign(
       oldest_seq: oldest_seq(events) || oldest,
       more_events?: length(events) == @page
     )}
  end

  ## Live updates

  @impl true
  def handle_info({:c3_events, id, seq}, %{assigns: %{session: %{id: id}}} = socket)
      when seq > socket.assigns.last_seq,
      do: {:noreply, fetch_events(socket)}

  def handle_info({:c3_events, _id, _seq}, socket), do: {:noreply, socket}

  def handle_info({:c3_admin, {:purged, id}}, %{assigns: %{session: %{id: id}}} = socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Session #{socket.assigns.session.code} was purged.")
     |> push_navigate(to: ~p"/admin")}
  end

  def handle_info({:c3_admin, _message}, socket), do: {:noreply, socket}

  def handle_info(:reload, socket) do
    stale = socket.assigns.stale
    socket = assign(socket, stale: MapSet.new(), reload_scheduled?: false)

    with %{} = socket <- reload_session(socket) do
      {:noreply,
       socket
       |> then(&if(MapSet.member?(stale, :agents), do: load_agents(&1), else: &1))
       |> then(&if(MapSet.member?(stale, :threads), do: load_threads(&1), else: &1))
       |> then(&if(MapSet.member?(stale, :selected), do: reload_selected(&1), else: &1))}
    end
  end

  def handle_info(:tick, socket) do
    with %{} = socket <- reload_session(socket), do: {:noreply, load_agents(socket)}
  end

  # Every event since the last one shown, in pages of @page; what they touched goes stale.
  defp fetch_events(socket) do
    %{session: session, last_seq: last_seq, selected: selected} = socket.assigns

    case Events.list_after(session, last_seq, limit: @page) do
      [] ->
        socket

      events ->
        stale =
          Enum.reduce(events, socket.assigns.stale, fn event, stale ->
            stale
            |> add_if(event.type in @agent_types, :agents)
            |> add_if(event.type in @thread_types, :threads)
            |> add_if(selected && event.thread_id == selected.id, :selected)
          end)

        socket =
          events
          |> Enum.reduce(socket, &stream_insert(&2, :events, &1, at: 0))
          |> assign(last_seq: List.last(events).seq, stale: stale)
          |> schedule_reload()

        if length(events) == @page, do: fetch_events(socket), else: socket
    end
  end

  defp add_if(set, true, item), do: MapSet.put(set, item)
  defp add_if(set, _false, _item), do: set

  defp schedule_reload(%{assigns: %{reload_scheduled?: true}} = socket), do: socket

  defp schedule_reload(socket) do
    Process.send_after(self(), :reload, @debounce_ms)
    assign(socket, reload_scheduled?: true)
  end

  # The session row (status, counters, last activity). Gone = purged by the retention.
  defp reload_session(socket) do
    case Sessions.get_session_by_code(socket.assigns.session.code) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:info, "Session #{socket.assigns.session.code} is gone (purged).")
         |> push_navigate(to: ~p"/admin")}

      session ->
        assign(socket, session: session)
    end
  end

  defp load_agents(socket),
    do: stream(socket, :agents, Sessions.list_agents(socket.assigns.session), reset: true)

  defp load_threads(socket) do
    rows =
      for {thread, state} <- Admin.list_threads(socket.assigns.session),
          do: %{id: thread.id, thread: thread, state: state}

    stream(socket, :threads, rows, reset: true)
  end

  defp reload_selected(%{assigns: %{selected: nil}} = socket), do: socket

  # The thread too: a finish (here or by its agent) changes `finished_at`.
  defp reload_selected(%{assigns: %{selected: thread}} = socket) do
    case Admin.get_thread(socket.assigns.session, thread.number) do
      {thread, messages} ->
        socket |> assign(selected: thread) |> stream(:messages, messages, reset: true)

      nil ->
        socket
    end
  end

  defp last_seq([newest | _]), do: newest.seq
  defp last_seq([]), do: 0

  defp oldest_seq([]), do: nil
  defp oldest_seq(events), do: List.last(events).seq
end
