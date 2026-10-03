defmodule C3.Watch do
  @moduledoc """
  Which events of the feed concern one agent, and the one-line summary its watcher prints
  for each (spec, *Integración con los agentes › El watcher*).

  The watcher is a shell script with only `curl`: deciding here keeps it from parsing JSON
  with free text in it. An event concerns `me` when it is:

    * a request addressed to it — by name, by its label, or to `any` from someone else —
      in `thread.opened` or `message.posted` → `request`, with `importance <high|urgent>`
      and `ack` when the request has them
    * a note that asks it to acknowledge it (it is in `ack_from`) → `ack`
    * a response that resolves a request it wrote (`resolved_for`) → `answer`
    * the cancellation of a request it held, or of an unclaimed one addressed to it, by
      someone else → `cancelled`
    * the expiry of its own claim → `claim_expired`
    * another agent joining, for the agent that created the session (`AG1`), which is
      usually waiting for it to open the first thread → `joined`
    * a failed join or the join lock → `security`
    * the warning that the session will close → `closing_soon`
    * the close of the session, its own leave, or the admin revoking it → `stop`
    * a reservation that blocked it (it is among the `waiters`) released or expired →
      `reservation_free`

  What the agent did itself never wakes it. Lines have the form
  `<kind> <seq> <facts…>` — a `request` or `answer` with attachments ends its facts with
  `files <n>`, after any `importance` and `ack`; the only free text, a thread title, goes
  last, quoted, on one line and cut to 80 characters. A reservation's pattern, written by an
  agent, has no spaces or control characters, so it stays one fact; like a title, it is data.
  """
  alias C3.Events.Event
  alias C3.Sessions.Agent

  @title_max 80

  @doc "The summary line of `event` for `me`, or `nil` when it does not concern it."
  def line(%Event{} = event, %Agent{} = me) do
    with {kind, facts} <- relevant(event.type, event.payload, me),
         do: Enum.join([kind, event.seq | facts], " ") <> title(event, kind)
  end

  # Requests: a thread opened with several targets is one line, for the first that is me.
  defp relevant(:thread_opened, %{"opened_by" => by} = p, me) when by != me.name do
    p["to"]
    |> Enum.zip(p["requests"])
    |> Enum.find(fn {to, _ref} -> for_me?(to, by, me) end)
    |> case do
      {_to, ref} -> {"request", [ref, "from", by | flags(p, me) ++ files(p)]}
      nil -> nil
    end
  end

  defp relevant(:message_posted, %{"author" => by} = p, me) when by != me.name do
    case p["kind"] do
      "request" ->
        if for_me?(p["to"], by, me),
          do: {"request", [p["message"], "from", by | flags(p, me) ++ files(p)]}

      "note" ->
        if me.name in (p["ack_from"] || []),
          do: {"ack", [p["message"], "from", by | importance(p) ++ files(p)]}

      "response" ->
        if me.name in (p["resolved_for"] || []),
          do:
            {"answer",
             [p["message"], "from", by, "resolves", Enum.join(p["resolved"], ",") | files(p)]}

      _ ->
        nil
    end
  end

  defp relevant(:request_cancelled, %{"cancelled_by" => by} = p, me) when by != me.name do
    mine? =
      case p["claimed_by"] do
        nil -> for_me?(p["to"], p["author"], me)
        holder -> holder == me.name
      end

    if mine?, do: {"cancelled", [p["request"], "by", by]}
  end

  defp relevant(:request_claim_expired, %{"claimed_by" => name} = p, %{name: name}),
    do: {"claim_expired", [p["request"]]}

  defp relevant(:agent_joined, %{"name" => name} = p, %{number: 1} = me) when name != me.name,
    do: {"joined", [name | if(p["label"], do: ["label", p["label"]], else: [])]}

  defp relevant(:security_join_failed, p, _me), do: {"security", ["join_failed", "ip", p["ip"]]}

  defp relevant(:session_joins_locked, p, _me),
    do: {"security", ["joins_locked", "ips", p["distinct_ips"]]}

  defp relevant(:session_closing_soon, p, _me),
    do: {"closing_soon", [p["reason"], "closes_at", p["closes_at"]]}

  defp relevant(:session_closed, p, _me),
    do: {"stop", ["session_closed", "by", p["closed_by"], "reason", p["reason"]]}

  defp relevant(:agent_left, %{"name" => name}, %{name: name}), do: {"stop", ["you_left"]}
  defp relevant(:agent_revoked, %{"name" => name}, %{name: name}), do: {"stop", ["revoked"]}

  defp relevant(:reservation_released, %{"agent" => by} = p, me) when by != me.name do
    if me.name in (p["waiters"] || []),
      do: {"reservation_free", [p["reservation"], p["pattern"], "released_by", by]}
  end

  defp relevant(:reservation_expired, %{"agent" => by} = p, me) when by != me.name do
    if me.name in (p["waiters"] || []),
      do: {"reservation_free", [p["reservation"], p["pattern"], "expired", "held_by", by]}
  end

  defp relevant(_type, _payload, _me), do: nil

  # `importance <high|urgent>` when not normal, and `ack` when it asks `me` to acknowledge it.
  defp flags(p, me),
    do: importance(p) ++ if(me.name in (p["ack_from"] || []), do: ["ack"], else: [])

  defp importance(%{"importance" => importance}) when importance in ~w(high urgent),
    do: ["importance", importance]

  defp importance(_payload), do: []

  # `files <n>` when the message carries attachments.
  defp files(%{"attachments" => [_ | _] = names}), do: ["files", length(names)]
  defp files(_payload), do: []

  # A request target (`"AG2"`, `"label:x"`, `"any"`) that `me` may take; `any` excludes
  # the author.
  defp for_me?("any", author, me), do: author != me.name
  defp for_me?("label:" <> label, _author, me), do: label == me.label
  defp for_me?(name, _author, me), do: name == me.name

  defp title(%Event{thread: %{title: title}}, kind)
       when kind in ~w(request answer cancelled ack) do
    clean =
      title
      |> String.replace(~r/[[:cntrl:]\s]+/u, " ")
      |> String.replace("\"", "'")
      |> String.trim()
      |> String.slice(0, @title_max)

    ~s( "#{clean}")
  end

  defp title(_event, _kind), do: ""
end
