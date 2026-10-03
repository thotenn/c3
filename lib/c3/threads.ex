defmodule C3.Threads do
  @moduledoc """
  Threads, their messages and the state derived from their requests.

  There is no session process: every write runs in one transaction that starts by locking
  the thread's row (`lock_thread!/2`, an `UPDATE` that also bumps `lock_version`). On
  Postgres that row lock serializes the writers of a thread; SQLite already serializes every
  writer (`default_transaction_mode: :immediate`). Inside it, the write recomputes
  `threads.status` — a cache of `C3.Threads.Derivation` — before committing, so the cache
  never drifts from the requests.

  A claim is a conditional `UPDATE … WHERE request_state = 'open'`: of two agents racing for
  the same request, exactly one changes a row and the other gets a `409`.

  Errors are `{:error, reason}` with `reason` one of `:thread_not_found`,
  `{:invalid, message, details}`, `{:forbidden, message}`, `{:conflict, message, details}`,
  `{:too_large, message}` or a changeset.
  """
  import Ecto.Query

  alias C3.{Attachments, Config, Events, Knowledge, Repo}
  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.{Acks, Derivation, Message, Targets, Thread}

  @pending [:open, :claimed]

  import C3.Threads.Queries, only: [addressed_requests: 2, fetch_message: 2, request_rows: 1]
  import C3.Threads.Guards

  ## Refs (C3.Threads.Refs)

  defdelegate thread_ref(thread), to: C3.Threads.Refs
  defdelegate message_ref(thread, message), to: C3.Threads.Refs
  defdelegate parse_thread_ref(ref), to: C3.Threads.Refs
  defdelegate parse_message_ref(thread, ref), to: C3.Threads.Refs

  ## Reads (C3.Threads.Queries)

  defdelegate get_thread(session, number), to: C3.Threads.Queries
  defdelegate fetch_thread(agent, ref), to: C3.Threads.Queries
  defdelegate list_threads(session, opts \\ []), to: C3.Threads.Queries
  defdelegate list_messages(thread, opts \\ []), to: C3.Threads.Queries
  defdelegate preload_threads(threads), to: C3.Threads.Queries
  defdelegate preload_messages(messages), to: C3.Threads.Queries
  defdelegate states(threads), to: C3.Threads.Queries
  defdelegate state(thread), to: C3.Threads.Queries
  defdelegate inbox(agent), to: C3.Threads.Queries

  ## Writes

  @doc """
  Opens a thread: `attrs` `"title"`, `"body"`, `"to"` (omitted = `any`), `"attachments"`
  (`C3.Attachments`, shared by every request), and `"importance"` / `"ack_required"`
  (`C3.Threads.Acks`). Creates the thread and one request per target, and emits
  `thread.opened`.
  """
  def open_thread(%Agent{} = author, attrs) do
    now = now()

    with :ok <- check_body_size(attrs["body"]),
         {:ok, flags} <- Acks.check_attrs(:request, attrs),
         {:ok, files} <- Attachments.prepare(attrs["attachments"]),
         {:ok, targets} <- Targets.resolve(attrs["to"], author) do
      Attachments.with_cleanup(fn ->
        Repo.transaction(fn ->
          thread =
            %Thread{session_id: author.session_id, opened_by_agent_id: author.id}
            |> Thread.changeset(%{
              number: next_thread_number!(author.session_id),
              title: attrs["title"],
              last_message_at: now
            })
            |> Repo.insert()
            |> rollback_on_error()

          requests = insert_requests!(thread, author, attrs["body"], targets, nil, 1, flags)
          ack_from = ask_requests!(requests, targets, author, flags, now)
          Attachments.store!(thread.session_id, Enum.map(requests, &elem(&1, 0)), files, now)

          Events.append!(session(thread), :thread_opened,
            actor: author,
            thread: thread,
            payload:
              %{
                thread: thread_ref(thread),
                title: thread.title,
                opened_by: author.name,
                to: Enum.map(requests, &elem(&1, 1)),
                requests: Enum.map(requests, &message_ref(thread, elem(&1, 0)))
              }
              |> with_flags(flags, ack_from |> Map.values() |> List.flatten() |> Enum.uniq())
              |> with_attachments(files)
          )

          {thread, _state} = apply_state!(thread, nil, author)
          thread
        end)
      end)
    end
  end

  @doc """
  Posts to a thread: `attrs` `"kind"` (`request`, `response` or `note`), `"body"`, `"to"`
  (requests: one request per target; a note with `ack_required`: whom it asks), `"reply_to"`
  (`T3.2` or `2`), `"attachments"` (`C3.Attachments`; every request of the post carries them)
  and, for requests and notes, `"importance"` / `"ack_required"` (`C3.Threads.Acks`).

  A `response` resolves the request it replies to — or, without `reply_to`, every request of
  the thread the author may answer — claiming it on the way if nobody had, and acknowledges
  it. Returns `{:ok, %{thread, messages, resolved}}`.
  """
  def post_message(%Agent{} = author, %Thread{id: thread_id}, attrs) do
    now = now()

    with {:ok, kind} <- parse_kind(attrs["kind"]),
         :ok <- check_body_size(attrs["body"]),
         {:ok, flags} <- Acks.check_attrs(kind, attrs),
         {:ok, files} <- Attachments.prepare(attrs["attachments"]),
         {:ok, targets} <- post_targets(kind, flags, attrs["to"], author) do
      Attachments.with_cleanup(fn ->
        Repo.transaction(fn ->
          thread = lock_thread!(thread_id, now)
          if thread.finished_at, do: rollback_finished(thread)

          reply_to = fetch_reply_to!(thread, attrs["reply_to"])
          number = next_message_number!(thread)

          {messages, resolved, reply_to, ack_from} =
            case kind do
              :request ->
                requests =
                  insert_requests!(
                    thread,
                    author,
                    attrs["body"],
                    targets,
                    reply_to,
                    number,
                    flags
                  )

                {requests, [], reply_to, ask_requests!(requests, targets, author, flags, now)}

              :response ->
                to_resolve = resolvable!(thread, author, reply_to)
                reply_to = reply_to || single(to_resolve)

                message =
                  insert_message!(thread, author, :response, attrs["body"], reply_to, number)

                resolve!(to_resolve, author, now)
                Acks.ack_implicitly!(author, Enum.map(to_resolve, & &1.id), now)
                {[{message, nil}], to_resolve, reply_to, %{}}

              :note ->
                message =
                  insert_message!(thread, author, :note, attrs["body"], reply_to, number, flags)

                {[{message, nil}], [], reply_to, ask_note!(message, targets, author, flags, now)}
            end

          Attachments.store!(thread.session_id, Enum.map(messages, &elem(&1, 0)), files, now)
          Thread |> where(id: ^thread.id) |> Repo.update_all(set: [last_message_at: now])
          resolved_refs = Enum.map(resolved, &message_ref(thread, &1))
          resolved_for = requesters(resolved)

          for {message, to} <- messages do
            Events.append!(session(thread), :message_posted,
              actor: author,
              thread: thread,
              message: message,
              payload:
                %{
                  thread: thread_ref(thread),
                  message: message_ref(thread, message),
                  kind: message.kind,
                  author: author.name,
                  to: to,
                  reply_to: reply_to && message_ref(thread, reply_to),
                  resolved: resolved_refs,
                  resolved_for: resolved_for
                }
                |> with_flags(flags, Map.get(ack_from, message.id, []))
                |> with_attachments(files)
            )
          end

          {thread, _state} = apply_state!(thread, thread.finished_at, author)

          %{
            thread: %{thread | last_message_at: now},
            messages: Enum.map(messages, &elem(&1, 0)),
            resolved: resolved_refs
          }
        end)
      end)
    end
  end

  @doc """
  Claims requests of a thread: `attrs["request_id"]` (`T3.2` or `2`), or by default every open
  request addressed to the agent. Claiming what the agent already holds is a no-op; a
  request held by someone else is a `409` that says who. Returns `{:ok, %{thread, claimed}}`.
  """
  def claim(%Agent{} = me, %Thread{id: thread_id}, attrs) do
    now = now()

    Repo.transaction(fn ->
      thread = lock_thread!(thread_id, now)
      if thread.finished_at, do: rollback_finished(thread)

      candidates =
        case attrs["request_id"] do
          nil -> addressed_requests(thread, me)
          ref -> [claimable_request!(thread, me, ref)]
        end

      {held, others} = Enum.split_with(candidates, &(&1.claimed_by_agent_id == me.id))
      open = for %Message{request_state: :open} = m <- others, do: m

      {_, claimed} =
        Message
        |> where([m], m.id in ^Enum.map(open, & &1.id) and m.request_state == :open)
        |> select([m], m)
        |> Repo.update_all(
          set: [request_state: :claimed, claimed_by_agent_id: me.id, claimed_at: now]
        )

      if held == [] and claimed == [] do
        holders =
          for %Message{request_state: :claimed} = m <- others, into: %{}, do: holder(thread, m)

        Repo.rollback(
          {:conflict, "Nothing to claim in #{thread_ref(thread)}", %{claimed_by: holders}}
        )
      end

      for message <- Enum.sort_by(claimed, & &1.number) do
        Events.append!(session(thread), :request_claimed,
          actor: me,
          thread: thread,
          message: message,
          payload: %{
            thread: thread_ref(thread),
            request: message_ref(thread, message),
            by: me.name
          }
        )
      end

      {thread, _state} = apply_state!(thread, thread.finished_at, me)
      Acks.ack_implicitly!(me, Enum.map(held ++ claimed, & &1.id), now)

      refs = (held ++ claimed) |> Enum.sort_by(& &1.number) |> Enum.map(&message_ref(thread, &1))
      %{thread: thread, claimed: refs}
    end)
  end

  @doc """
  Cancels one request that is still pending, `open` or `claimed`: `attrs["request_id"]`
  (`T3.2` or `2`) and an optional `attrs["reason"]`, posted as a `note` replying to it. Only
  the request's author or the agent that opened the thread can.

  Emits `request.cancelled` with the target and, if it was claimed, who held it: that is how
  the agent working on it learns to stop. A request already `done` or `cancelled` is a `409`
  (the answer won the race). Returns `{:ok, %{thread, cancelled, note}}`.
  """
  def cancel(%Agent{} = me, %Thread{id: thread_id}, attrs) do
    now = now()
    reason = blank_to_nil(attrs["reason"])

    with :ok <- check_reason(reason), {:ok, ref} <- require_request_id(attrs["request_id"]) do
      Repo.transaction(fn ->
        thread = lock_thread!(thread_id, now)
        request = cancellable_request!(thread, me, ref)
        request_ref = message_ref(thread, request)

        {1, _} =
          Message
          |> where([m], m.id == ^request.id and m.request_state in ^@pending)
          |> Repo.update_all(
            set: [
              request_state: :cancelled,
              claimed_by_agent_id: nil,
              claimed_at: nil,
              resolved_at: now
            ]
          )

        Events.append!(session(thread), :request_cancelled,
          actor: me,
          thread: thread,
          message: request,
          payload: %{
            thread: thread_ref(thread),
            request: request_ref,
            author: request.author_agent.name,
            to: Targets.display(request.to_target, request.to_label, to_name(request)),
            cancelled_by: me.name,
            claimed_by: request.claimed_by_agent && request.claimed_by_agent.name,
            reason: reason
          }
        )

        note =
          if reason do
            note =
              insert_message!(thread, me, :note, reason, request, next_message_number!(thread))

            Thread |> where(id: ^thread.id) |> Repo.update_all(set: [last_message_at: now])

            Events.append!(session(thread), :message_posted,
              actor: me,
              thread: thread,
              message: note,
              payload: %{
                thread: thread_ref(thread),
                message: message_ref(thread, note),
                kind: :note,
                author: me.name,
                to: nil,
                reply_to: request_ref,
                resolved: [],
                resolved_for: []
              }
            )

            message_ref(thread, note)
          end

        {thread, _state} = apply_state!(thread, thread.finished_at, me)
        %{thread: thread, cancelled: request_ref, note: note}
      end)
    end
  end

  @doc """
  Finishes a thread. Only the agent that opened it can. With pending requests it is a `409`
  unless `attrs["force"]` is true, which cancels them — each with a `request.cancelled`, so
  the agent working on one learns to stop, as with `cancel/3`. Finishing a finished thread
  is a no-op. Returns `{:ok, %{thread, changed, cancelled, recorded}}`.

  `attrs["record"]` (`topic`, `kind`, `summary`, optional `supersedes`) records what the
  thread ended with in `C3.Knowledge`, in the same transaction, with the thread as its
  `source`; `recorded` is that entry, or `nil`. A finish that changes nothing records nothing,
  so a retry does not record twice.
  """
  def finish(%Agent{} = me, %Thread{} = thread, attrs) do
    with {:ok, record} <- record_attrs(attrs["record"]) do
      finish_thread(thread, me, attrs["force"] in [true, "true"], record)
    end
  end

  defp record_attrs(nil), do: {:ok, nil}
  defp record_attrs(record), do: Knowledge.check_attrs(record)

  @doc """
  The admin finishes a thread (spec, decision 10): always forced, the pending requests are
  cancelled with `cancelled_by: "admin"`. Same result as `finish/3`.
  """
  def admin_finish(%Thread{} = thread), do: finish_thread(thread, :admin, true, nil)

  defp finish_thread(%Thread{id: thread_id}, me, force?, record) do
    now = now()
    actor = if match?(%Agent{}, me), do: me
    by = if actor, do: actor.name, else: "admin"

    Repo.transaction(fn ->
      thread = lock_thread!(thread_id, now)
      if actor, do: check_opened_by!(thread, actor)

      if thread.finished_at do
        %{thread: thread, changed: false, cancelled: [], recorded: nil}
      else
        pending =
          Message
          |> where([m], m.thread_id == ^thread.id and m.request_state in ^@pending)
          |> order_by(:number)
          |> Repo.all()
          |> Repo.preload([:author_agent, :to_agent, :claimed_by_agent])

        refs = Enum.map(pending, &message_ref(thread, &1))

        if pending != [] and not force? do
          Repo.rollback(
            {:conflict,
             "#{thread_ref(thread)} has pending requests; finish with force to cancel them",
             %{pending: refs}}
          )
        end

        Message
        |> where([m], m.id in ^Enum.map(pending, & &1.id))
        |> Repo.update_all(
          set: [
            request_state: :cancelled,
            claimed_by_agent_id: nil,
            claimed_at: nil,
            resolved_at: now
          ]
        )

        for request <- pending do
          Events.append!(session(thread), :request_cancelled,
            actor: actor,
            thread: thread,
            message: request,
            payload: %{
              thread: thread_ref(thread),
              request: message_ref(thread, request),
              author: request.author_agent.name,
              to: Targets.display(request.to_target, request.to_label, to_name(request)),
              cancelled_by: by,
              claimed_by: request.claimed_by_agent && request.claimed_by_agent.name,
              reason: "thread finished"
            }
          )
        end

        recorded =
          record && Knowledge.record!(actor, Map.put(record, "source", thread_ref(thread)))

        {thread, _state} = apply_state!(thread, now, actor, %{cancelled: refs})
        %{thread: thread, changed: true, cancelled: refs, recorded: recorded}
      end
    end)
  end

  @doc """
  Reopens a finished thread; its status is derived again (`answered`, since finishing left no
  pending request). Only the agent that opened it can. A no-op on a thread that is not
  finished. Returns `{:ok, %{thread, changed}}`.
  """
  def reopen(%Agent{} = me, %Thread{id: thread_id}) do
    now = now()

    Repo.transaction(fn ->
      thread = lock_thread!(thread_id, now)
      check_opened_by!(thread, me)

      if thread.finished_at do
        {thread, _state} = apply_state!(thread, nil, me)
        %{thread: thread, changed: true}
      else
        %{thread: thread, changed: false}
      end
    end)
  end

  @doc """
  Acknowledges messages of a thread that asked the agent to (`C3.Threads.Acks.ack!/4`):
  `attrs["message"]` (`T3.4` or `4`), or every pending one of the thread. Also on a finished
  thread. Returns `{:ok, %{thread, acked}}`.
  """
  def ack(%Agent{} = me, %Thread{id: thread_id}, attrs) do
    now = now()

    Repo.transaction(fn ->
      thread = lock_thread!(thread_id, now)
      %{thread: thread, acked: Acks.ack!(me, thread, attrs, now)}
    end)
  end

  @doc """
  Puts every request `agent` claimed back to `open`, for `C3.Sessions.leave/1`. Call inside
  a transaction, then `refresh_threads!/2` with the thread ids. Returns `{refs, thread_ids}`.
  """
  def release_claims!(%Agent{id: agent_id}) do
    rows =
      Message
      |> join(:inner, [m], t in Thread, on: t.id == m.thread_id)
      |> where([m], m.claimed_by_agent_id == ^agent_id and m.request_state == :claimed)
      |> order_by([m, t], [t.number, m.number])
      |> select([m, t], {m.id, t.id, t.number, m.number})
      |> Repo.all()

    thread_ids = rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
    now = now()
    Enum.each(thread_ids, &lock_thread!(&1, now))

    Message
    |> where([m], m.id in ^Enum.map(rows, &elem(&1, 0)))
    |> Repo.update_all(set: [request_state: :open, claimed_by_agent_id: nil, claimed_at: nil])

    {Enum.map(rows, fn {_, _, t, m} -> message_ref(t, m) end), thread_ids}
  end

  @doc "Recomputes the cached status of threads whose requests changed. Call in a transaction."
  def refresh_threads!(thread_ids, actor) do
    for thread <- Repo.all(from t in Thread, where: t.id in ^thread_ids, order_by: t.id) do
      apply_state!(thread, thread.finished_at, actor)
    end

    :ok
  end

  @doc """
  Puts back to `open` every claim whose agent has not been seen (`agents.last_seen_at`) for
  `claim_ttl`, with a `request.claim_expired` event each. Run by `C3.Sweeper`; returns how
  many it released.
  """
  def expire_claims(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -Config.get(:claim_ttl), :second)
    silent = from a in Agent, where: a.last_seen_at < ^cutoff, select: a.id

    expired =
      from m in Message,
        join: s in Session,
        on: s.id == m.session_id,
        where:
          s.status == :open and m.request_state == :claimed and m.claimed_at < ^cutoff and
            m.claimed_by_agent_id in subquery(silent)

    thread_ids = expired |> select([m], m.thread_id) |> distinct(true) |> Repo.all()

    Enum.reduce(thread_ids, 0, fn thread_id, count ->
      {:ok, released} =
        Repo.transaction(fn ->
          thread = lock_thread!(thread_id, now)

          rows =
            expired
            |> where([m], m.thread_id == ^thread_id)
            |> join(:inner, [m], a in Agent, on: a.id == m.claimed_by_agent_id)
            |> order_by([m], m.number)
            |> select([m, s, a], {m.id, m.number, a.name})
            |> Repo.all()

          Message
          |> where([m], m.id in ^Enum.map(rows, &elem(&1, 0)))
          |> Repo.update_all(
            set: [request_state: :open, claimed_by_agent_id: nil, claimed_at: nil]
          )

          for {id, number, name} <- rows do
            Events.append!(session(thread), :request_claim_expired,
              thread: thread,
              message: id,
              payload: %{
                thread: thread_ref(thread),
                request: message_ref(thread.number, number),
                claimed_by: name
              }
            )
          end

          apply_state!(thread, thread.finished_at, nil)
          length(rows)
        end)

      count + released
    end)
  end

  ## Derived state

  # Writes the derived status (and finished_at, which the CHECK ties to it) and emits
  # thread.status_changed when the status moved.
  defp apply_state!(%Thread{} = thread, finished_at, actor, extra \\ %{}) do
    rows = request_rows([thread.id]) |> Map.get(thread.id, [])
    state = Derivation.derive(not is_nil(finished_at), rows)

    if state.status != thread.status or finished_at != thread.finished_at do
      Thread
      |> where(id: ^thread.id)
      |> Repo.update_all(set: [status: state.status, finished_at: finished_at])
    end

    if state.status != thread.status do
      Events.append!(session(thread), :thread_status_changed,
        actor: actor,
        thread: thread,
        payload:
          Map.merge(
            %{
              thread: thread_ref(thread),
              from: thread.status,
              to: state.status,
              awaiting: state.awaiting,
              processing_by: state.processing_by
            },
            extra
          )
      )
    end

    {%{thread | status: state.status, finished_at: finished_at}, state}
  end

  ## Helpers of the writes

  defp lock_thread!(thread_id, now) do
    {1, [thread]} =
      Thread
      |> where(id: ^thread_id)
      |> select([t], t)
      |> Repo.update_all(set: [updated_at: now], inc: [lock_version: 1])

    thread
  end

  defp next_thread_number!(session_id) do
    {1, [next]} =
      Session
      |> where(id: ^session_id)
      |> select([s], s.next_thread_number)
      |> Repo.update_all(inc: [next_thread_number: 1])

    next - 1
  end

  defp next_message_number!(%Thread{id: thread_id}) do
    Message
    |> where(thread_id: ^thread_id)
    |> select([m], coalesce(max(m.number), 0))
    |> Repo.one()
    |> Kernel.+(1)
  end

  # [{message, to_display}], one request per target, numbered from `number`.
  defp insert_requests!(thread, author, body, targets, reply_to, number, flags) do
    targets
    |> Enum.with_index(number)
    |> Enum.map(fn {target, n} ->
      {fields, attrs, to} =
        case target do
          {:agent, %Agent{} = agent} ->
            {[to_agent_id: agent.id], %{to_target: :agent}, agent.name}

          {:label, label} ->
            {[], %{to_target: :label, to_label: label}, "label:" <> label}

          :any ->
            {[], %{to_target: :any}, "any"}
        end

      message =
        thread
        |> message_struct(author, reply_to, fields)
        |> Message.changeset(
          attrs
          |> Map.merge(%{number: n, kind: :request, body: body, request_state: :open})
          |> Map.merge(flags)
        )
        |> Repo.insert()
        |> rollback_on_error()

      {message, to}
    end)
  end

  defp insert_message!(thread, author, kind, body, reply_to, number, flags \\ %{}) do
    thread
    |> message_struct(author, reply_to, [])
    |> Message.changeset(Map.merge(%{number: number, kind: kind, body: body}, flags))
    |> Repo.insert()
    |> rollback_on_error()
  end

  defp message_struct(thread, author, reply_to, fields) do
    struct!(
      %Message{
        thread_id: thread.id,
        session_id: thread.session_id,
        author_agent_id: author.id,
        reply_to_message_id: reply_to && reply_to.id
      },
      fields
    )
  end

  defp fetch_reply_to!(_thread, nil), do: nil

  defp fetch_reply_to!(thread, ref) do
    case fetch_message(thread, ref) do
      {:ok, message} -> message
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp to_name(%Message{to_agent: %Agent{name: name}}), do: name
  defp to_name(%Message{}), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp resolve!([], _me, _now), do: :ok

  defp resolve!(requests, me, now) do
    {open, claimed} = Enum.split_with(requests, &(&1.request_state == :open))

    Message
    |> where([m], m.id in ^Enum.map(open, & &1.id) and m.request_state == :open)
    |> Repo.update_all(
      set: [request_state: :done, claimed_by_agent_id: me.id, claimed_at: now, resolved_at: now]
    )

    Message
    |> where([m], m.id in ^Enum.map(claimed, & &1.id) and m.claimed_by_agent_id == ^me.id)
    |> Repo.update_all(set: [request_state: :done, resolved_at: now])

    :ok
  end

  # The names of the agents that wrote `requests`, in order and without repeats: who an
  # answer is for, so the watcher can wake them.
  defp requesters([]), do: []

  defp requesters(requests) do
    ids = requests |> Enum.map(& &1.author_agent_id) |> Enum.uniq()
    names = Agent |> where([a], a.id in ^ids) |> select([a], {a.id, a.name}) |> Repo.all()
    names = Map.new(names)
    Enum.map(ids, &Map.fetch!(names, &1))
  end

  defp single([one]), do: one
  defp single(_), do: nil

  # A note asks for an ack only through `to`; without `ack_required` it takes none.
  defp post_targets(:note, %{ack_required: true}, to, author), do: Acks.note_targets(to, author)
  defp post_targets(kind, _flags, to, author), do: targets_for(kind, to, author)

  # %{message_id => names asked to acknowledge it}; one request per target, in order.
  defp ask_requests!(_requests, _targets, _author, %{ack_required: false}, _now), do: %{}

  defp ask_requests!(requests, targets, author, _flags, now) do
    Enum.zip_with(requests, targets, fn {message, _to}, target ->
      {message.id, Acks.ask!(message, Acks.recipients(author, target), now)}
    end)
    |> Map.new()
  end

  defp ask_note!(_note, _targets, _author, %{ack_required: false}, _now), do: %{}

  defp ask_note!(note, targets, author, _flags, now) do
    recipients = Enum.flat_map(targets, &Acks.recipients(author, &1))
    %{note.id => Acks.ask!(note, recipients, now)}
  end

  # The importance of a message and whom it asks to acknowledge it, when not the default.
  defp with_flags(payload, %{importance: importance, ack_required: ack?}, ack_from) do
    payload
    |> then(&if importance != :normal, do: Map.put(&1, :importance, importance), else: &1)
    |> then(&if ack?, do: Map.put(&1, :ack_from, ack_from), else: &1)
  end

  # An event payload names the files of the post, when it has any.
  defp with_attachments(payload, []), do: payload

  defp with_attachments(payload, files),
    do: Map.put(payload, :attachments, Enum.map(files, & &1.filename))

  defp session(%Thread{session_id: id}), do: %Session{id: id}

  defp rollback_on_error({:ok, record}), do: record
  defp rollback_on_error({:error, changeset}), do: Repo.rollback(changeset)

  defp now, do: DateTime.utc_now()
end
