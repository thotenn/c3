defmodule C3Web.Admin.Components do
  @moduledoc "Small pieces shared by the admin LiveViews: badges, times, event summaries."
  use Phoenix.Component

  alias C3.Events.Event

  attr :session, :map, required: true

  def session_status(assigns) do
    ~H"""
    <span :if={@session.status == :open} class={[badge(), "bg-success/15 text-success"]}>
      open<span :if={@session.joins_locked_at}> · joins locked</span>
    </span>
    <span
      :if={@session.status == :closed}
      class={[badge(), "bg-base-300 text-base-content/70"]}
      title={"closed by #{@session.closed_by}"}
    >
      closed · {@session.close_reason}
    </span>
    """
  end

  attr :status, :atom, required: true

  def thread_status(assigns) do
    ~H"""
    <span class={[badge(), thread_color(@status)]}>{@status}</span>
    """
  end

  defp thread_color(:pending), do: "bg-warning/15 text-warning"
  defp thread_color(:processing), do: "bg-info/15 text-info"
  defp thread_color(:answered), do: "bg-success/15 text-success"
  defp thread_color(:finished), do: "bg-base-300 text-base-content/70"

  attr :status, :atom, required: true

  def agent_status(assigns) do
    ~H"""
    <span class={[badge(), agent_color(@status)]}>{@status}</span>
    """
  end

  defp agent_color(:active), do: "bg-success/15 text-success"
  defp agent_color(:revoked), do: "bg-error/15 text-error"
  defp agent_color(:left), do: "bg-base-300 text-base-content/70"

  defp badge, do: "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium"

  attr :at, :any, required: true

  @doc "A UTC time, short, with the full ISO 8601 value as its title."
  def time(assigns) do
    ~H"""
    <time :if={@at} datetime={DateTime.to_iso8601(@at)} title={DateTime.to_iso8601(@at)}>
      {Calendar.strftime(@at, "%Y-%m-%d %H:%M:%S")}
    </time>
    <span :if={!@at} class="text-base-content/40">—</span>
    """
  end

  @doc "A byte count for people: `512 B`, `3.4 KB`, `1.2 MB`."
  def format_bytes(n) when n < 1024, do: "#{n} B"
  def format_bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  def format_bytes(n), do: "#{Float.round(n / (1024 * 1024), 1)} MB"

  @doc "The dotted type of an event (`thread.opened`)."
  def event_type(%Event{type: type}), do: Ecto.Enum.mappings(Event, :type)[type]

  @doc "One readable line about an event, from its payload (string keys, as stored)."
  def event_summary(%Event{type: type, payload: p}) do
    case type do
      :agent_joined ->
        "#{p["name"]} joined#{label(p["label"])}"

      :agent_left ->
        "#{p["name"]} left#{released(p["released"])}"

      :agent_revoked ->
        "#{p["name"]} revoked by #{p["by"]}#{released(p["released"])}"

      :thread_opened ->
        "#{p["opened_by"]} opened #{p["thread"]} → #{list(p["to"])}"

      :message_posted ->
        message_summary(p)

      :thread_status_changed ->
        "#{p["thread"]} #{p["from"]} → #{p["to"]}"

      :request_claimed ->
        "#{p["by"]} claimed #{p["request"]}"

      :request_claim_expired ->
        "claim of #{p["claimed_by"]} on #{p["request"]} expired"

      :request_cancelled ->
        "#{p["cancelled_by"]} cancelled #{p["request"]}#{reason(p)}"

      :security_join_failed ->
        "wrong security number from #{p["ip"]}#{label(p["attempted_label"])}"

      :session_joins_locked ->
        "joins locked after #{p["distinct_ips"]} IPs"

      :session_joins_unlocked ->
        "joins unlocked by #{p["by"]}"

      :session_secret_rotated ->
        "security number rotated by #{p["by"]}#{if p["unlocked"], do: "; joins unlocked", else: ""}"

      :session_closing_soon ->
        "closes at #{p["closes_at"]} (#{p["reason"]})"

      :session_closed ->
        "closed by #{p["closed_by"]} (#{p["reason"]})"

      :knowledge_recorded ->
        supersedes = if p["supersedes"], do: ", supersedes #{p["supersedes"]}", else: ""
        "#{p["author"]} recorded #{p["entry"]} #{p["kind"]} on #{p["topic"]}#{supersedes}"

      :knowledge_superseded ->
        "#{p["entry"]} superseded by #{p["superseded_by"]} (#{p["by"]})"

      :knowledge_retracted ->
        "#{p["by"]} retracted #{p["entry"]}#{reason(p)}"
    end
  end

  defp message_summary(p) do
    to = if p["to"], do: " → #{p["to"]}", else: ""
    resolves = if p["resolved"] in [nil, []], do: "", else: ", resolves #{list(p["resolved"])}"
    files = if p["attachments"] in [nil, []], do: "", else: " [#{list(p["attachments"])}]"
    "#{p["author"]} posted #{p["kind"]} #{p["message"]}#{to}#{resolves}#{files}"
  end

  defp label(nil), do: ""
  defp label(label), do: " (label #{label})"

  defp released(refs) when refs in [nil, []], do: ""
  defp released(refs), do: "; released #{list(refs)}"

  defp reason(%{"reason" => reason}) when is_binary(reason) and reason != "", do: ": #{reason}"
  defp reason(_payload), do: ""

  defp list(items) when is_list(items), do: Enum.join(items, ", ")
  defp list(item), do: to_string(item)
end
