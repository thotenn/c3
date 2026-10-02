defmodule C3Web.Admin.SessionsLive do
  @moduledoc """
  The admin's front page: every session in the database (open, and closed within the
  retention) and the IP bans in force, with the unban action.

  Live without a query per event: every announcement of the `admin` topic only marks the
  page stale, and it reloads at most once per `@debounce_ms`. A slow tick also reloads it,
  for what changes without an event (last activity, bans for unknown codes, expiries).
  """
  use C3Web, :live_view

  import C3Web.Admin.Components

  alias C3.{Admin, Events}

  @debounce_ms 1_000
  @tick_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_admin()
      :timer.send_interval(@tick_ms, :tick)
    end

    {:ok,
     socket
     |> assign(page_title: "Sessions", reload_scheduled?: false)
     |> stream_configure(:sessions, dom_id: &"session-#{&1.session.id}")
     |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} admin wide>
      <div class="flex items-end justify-between">
        <h1 class="text-2xl font-semibold tracking-tight">Sessions</h1>
        <p class="text-sm text-base-content/60">
          {@open_count} open · {@session_count} total
        </p>
      </div>

      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="w-full text-sm">
          <thead class="bg-base-200 text-left text-xs uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="px-3 py-2">Code</th>
              <th class="px-3 py-2">Label</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Agents</th>
              <th class="px-3 py-2">Threads</th>
              <th class="px-3 py-2">Last activity</th>
              <th class="px-3 py-2">Created</th>
            </tr>
          </thead>
          <tbody id="sessions" phx-update="stream">
            <tr id="sessions-empty" class="hidden only:table-row">
              <td colspan="7" class="px-3 py-6 text-center text-base-content/60">
                No sessions.
              </td>
            </tr>
            <tr
              :for={{id, row} <- @streams.sessions}
              id={id}
              class="border-t border-base-300 hover:bg-base-200/60 transition-colors"
            >
              <td class="px-3 py-2 font-mono">
                <.link navigate={~p"/admin/sessions/#{row.session.code}"} class="hover:underline">
                  {row.session.code}
                </.link>
              </td>
              <td class="px-3 py-2">{row.session.label}</td>
              <td class="px-3 py-2"><.session_status session={row.session} /></td>
              <td class="px-3 py-2 tabular-nums">{row.agents_active} / {row.agents_total}</td>
              <td class="px-3 py-2 tabular-nums">
                {row.threads_total}
                <span :if={row.threads_open > 0} class="text-warning">
                  ({row.threads_open} open)
                </span>
              </td>
              <td class="px-3 py-2"><.time at={row.session.last_activity_at} /></td>
              <td class="px-3 py-2"><.time at={row.session.inserted_at} /></td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2 class="pt-4 text-lg font-semibold tracking-tight">IP bans in force</h2>
      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="w-full text-sm">
          <thead class="bg-base-200 text-left text-xs uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="px-3 py-2">IP</th>
              <th class="px-3 py-2">Reason</th>
              <th class="px-3 py-2">Session</th>
              <th class="px-3 py-2">Banned until</th>
              <th class="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody id="bans" phx-update="stream">
            <tr id="bans-empty" class="hidden only:table-row">
              <td colspan="5" class="px-3 py-6 text-center text-base-content/60">No bans.</td>
            </tr>
            <tr :for={{id, ban} <- @streams.bans} id={id} class="border-t border-base-300">
              <td class="px-3 py-2 font-mono">{ban.ip}</td>
              <td class="px-3 py-2">{ban.reason}</td>
              <td class="px-3 py-2 font-mono">{ban.session_code}</td>
              <td class="px-3 py-2"><.time at={ban.banned_until} /></td>
              <td class="px-3 py-2 text-right">
                <button
                  id={"unban-#{ban.id}"}
                  phx-click="unban"
                  phx-value-ip={ban.ip}
                  data-confirm={"Lift the ban of #{ban.ip}?"}
                  class="rounded border border-base-300 px-2 py-1 text-xs hover:bg-base-200 transition-colors"
                >
                  Unban
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("unban", %{"ip" => ip}, socket) do
    {:ok, lifted} = Admin.unban(ip)
    message = if lifted > 0, do: "Lifted the ban of #{ip}.", else: "#{ip} was not banned."
    {:noreply, socket |> put_flash(:info, message) |> load()}
  end

  @impl true
  def handle_info({:c3_events, _id, _seq}, socket), do: {:noreply, schedule(socket)}
  def handle_info({:c3_admin, _message}, socket), do: {:noreply, schedule(socket)}
  def handle_info(:tick, socket), do: {:noreply, load(socket)}

  def handle_info(:reload, socket),
    do: {:noreply, socket |> assign(reload_scheduled?: false) |> load()}

  defp schedule(%{assigns: %{reload_scheduled?: true}} = socket), do: socket

  defp schedule(socket) do
    Process.send_after(self(), :reload, @debounce_ms)
    assign(socket, reload_scheduled?: true)
  end

  defp load(socket) do
    rows = Admin.list_sessions()

    socket
    |> assign(
      session_count: length(rows),
      open_count: Enum.count(rows, &(&1.session.status == :open))
    )
    |> stream(:sessions, rows, reset: true)
    |> stream(:bans, Admin.list_active_bans(), reset: true)
  end
end
