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

  alias C3.{Attachments, Config, Events, Repo}
  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.{Derivation, Message, Targets, Thread}

  @kinds %{"request" => :request, "response" => :response, "note" => :note}
  @pending [:open, :claimed]

  ## Refs

  @doc "The readable id of a thread, `T<number>`."
  def thread_ref(%Thread{number: number}), do: "T#{number}"

  @doc "The readable id of a message, `T<thread>.<number>`."
  def message_ref(%Thread{number: thread}, %Message{number: number}), do: "T#{thread}.#{number}"
  def message_ref(thread_number, number), do: "T#{thread_number}.#{number}"

  ## Reads

  @doc "Thread `T<number>` of a session, or `nil`."
  def get_thread(%Session{id: session_id}, number) when is_integer(number) do
    Repo.get_by(Thread, session_id: session_id, number: number)
  end

  @doc "The thread with readable id `ref` (`T3`) in the agent's session."
  def fetch_thread(%Agent{session_id: session_id}, ref) do
    with {:ok, number} <- parse_thread_ref(ref),
         %Thread{} = thread <- Repo.get_by(Thread, session_id: session_id, number: number) do
      {:ok, thread}
    else
      _ -> {:error, :thread_not_found}
    end
  end

  @doc """
  The threads of a session, most recently active first.

  Options: `:status` keeps only the threads with that status; `:awaiting` (an `Agent`) only
  those with an open request addressed to it; `:preload` preloads.
  """
  def list_threads(%Session{id: session_id}, opts \\ []) do
    Thread
    |> where(session_id: ^session_id)
    |> filter_status(opts[:status])
    |> filter_awaiting(opts[:awaiting])
    |> order_by(desc: :last_message_at, desc: :number)
    |> preload(^Keyword.get(opts, :preload, []))
    |> Repo.all()
  end

  @doc """
  The messages of a thread, in order, with their agents and `reply_to` preloaded.

  Options: `:since` keeps only the messages after that number.
  """
  def list_messages(%Thread{id: thread_id}, opts \\ []) do
    Message
    |> where(thread_id: ^thread_id)
    |> filter_since(opts[:since])
    |> order_by(:number)
    |> Repo.all()
    |> preload_messages()
  end

  @doc "Preloads what the JSON of a thread shows (`opened_by_agent`)."
  def preload_threads(threads), do: Repo.preload(threads, :opened_by_agent)

  @doc "Preloads what the JSON of a message shows (its agents and `reply_to`)."
  def preload_messages(messages) do
    Repo.preload(messages, [
      :author_agent,
      :to_agent,
      :claimed_by_agent,
      :reply_to_message,
      attachments: from(a in C3.Threads.Attachment, order_by: a.id)
    ])
  end

  @doc "The derived state (`C3.Threads.Derivation`) of each thread, by thread id."
  def states(threads) when is_list(threads) do
    rows = request_rows(Enum.map(threads, & &1.id))

    Map.new(threads, fn thread ->
      {thread.id, Derivation.derive(finished?(thread), Map.get(rows, thread.id, []))}
    end)
  end

  @doc "The derived state of one thread."
  def state(%Thread{} = thread), do: states([thread]) |> Map.fetch!(thread.id)

  @doc """
  What an agent has to do: the open requests addressed to it (by name, by its label or to
  `any` from someone else) and the ones it claimed, grouped by thread in thread order.
  Returns `[{thread, requests}]`, with `opened_by_agent` and the requests' agents preloaded.
  """
  def inbox(%Agent{} = me) do
    mine = dynamic([m], m.request_state == :claimed and m.claimed_by_agent_id == ^me.id)
    open = dynamic([m], m.request_state == :open and ^addressed_to(me))

    Message
    |> join(:inner, [m], t in Thread, on: t.id == m.thread_id)
    |> where([m], m.session_id == ^me.session_id and m.kind == :request)
    |> where(^dynamic([m], ^open or ^mine))
    |> order_by([m, t], [t.number, m.number])
    |> preload([m, t], thread: {t, :opened_by_agent})
    |> Repo.all()
    |> preload_messages()
    |> Enum.chunk_by(& &1.thread_id)
    |> Enum.map(fn [first | _] = requests -> {first.thread, requests} end)
  end

  ## Writes

  @doc """
  Opens a thread: `attrs` `"title"`, `"body"`, `"to"` (omitted = `any`) and `"attachments"`
  (`C3.Attachments`, shared by every request). Creates the thread and one request per
  target, and emits `thread.opened`.
  """
  def open_thread(%Agent{} = author, attrs) do
    now = now()

    with :ok <- check_body_size(attrs["body"]),
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

          requests = insert_requests!(thread, author, attrs["body"], targets, nil, 1)
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
  (requests only; one request per target), `"reply_to"` (`T3.2` or `2`) and `"attachments"`
  (`C3.Attachments`; every request of the post carries them).

  A `response` resolves the request it replies to — or, without `reply_to`, every request of
  the thread the author may answer — claiming it on the way if nobody had. Returns
  `{:ok, %{thread, messages, resolved}}`.
  """
  def post_message(%Agent{} = author, %Thread{id: thread_id}, attrs) do
    now = now()

    with {:ok, kind} <- parse_kind(attrs["kind"]),
         :ok <- check_body_size(attrs["body"]),
         {:ok, files} <- Attachments.prepare(attrs["attachments"]),
         {:ok, targets} <- targets_for(kind, attrs["to"], author) do
      Attachments.with_cleanup(fn ->
        Repo.transaction(fn ->
          thread = lock_thread!(thread_id, now)
          if thread.finished_at, do: rollback_finished(thread)

          reply_to = fetch_reply_to!(thread, attrs["reply_to"])
          number = next_message_number!(thread)

          {messages, resolved, reply_to} =
            case kind do
              :request ->
                requests =
                  insert_requests!(thread, author, attrs["body"], targets, reply_to, number)

                {requests, [], reply_to}

              :response ->
                to_resolve = resolvable!(thread, author, reply_to)
                reply_to = reply_to || single(to_resolve)

                message =
                  insert_message!(thread, author, :response, attrs["body"], reply_to, number)

                resolve!(to_resolve, author, now)
                {[{message, nil}], to_resolve, reply_to}

              :note ->
                message = insert_message!(thread, author, :note, attrs["body"], reply_to, number)
                {[{message, nil}], [], reply_to}
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
  is a no-op. Returns `{:ok, %{thread, changed, cancelled}}`.
  """
  def finish(%Agent{} = me, %Thread{} = thread, attrs) do
    finish_thread(thread, me, attrs["force"] in [true, "true"])
  end

  @doc """
  The admin finishes a thread (spec, decision 10): always forced, the pending requests are
  cancelled with `cancelled_by: "admin"`. Same result as `finish/3`.
  """
  def admin_finish(%Thread{} = thread), do: finish_thread(thread, :admin, true)

  defp finish_thread(%Thread{id: thread_id}, me, force?) do
    now = now()
    actor = if match?(%Agent{}, me), do: me
    by = if actor, do: actor.name, else: "admin"

    Repo.transaction(fn ->
      thread = lock_thread!(thread_id, now)
      if actor, do: check_opened_by!(thread, actor)

      if thread.finished_at do
        %{thread: thread, changed: false, cancelled: []}
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

        {thread, _state} = apply_state!(thread, now, actor, %{cancelled: refs})
        %{thread: thread, changed: true, cancelled: refs}
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

  defp request_rows([]), do: %{}

  defp request_rows(thread_ids) do
    Message
    |> where([m], m.thread_id in ^thread_ids and m.kind == :request)
    |> join(:left, [m], ta in Agent, on: ta.id == m.to_agent_id)
    |> join(:left, [m], cb in Agent, on: cb.id == m.claimed_by_agent_id)
    |> order_by([m], [m.thread_id, m.number])
    |> select(
      [m, ta, cb],
      {m.thread_id, m.request_state, m.to_target, m.to_label, ta.name, cb.name}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_, state, target, label, name, claimed_by} ->
      %{state: state, to: Targets.display(target, label, name), claimed_by: claimed_by}
    end)
  end

  defp finished?(%Thread{finished_at: finished_at}), do: not is_nil(finished_at)

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
  defp insert_requests!(thread, author, body, targets, reply_to, number) do
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
          Map.merge(attrs, %{number: n, kind: :request, body: body, request_state: :open})
        )
        |> Repo.insert()
        |> rollback_on_error()

      {message, to}
    end)
  end

  defp insert_message!(thread, author, kind, body, reply_to, number) do
    thread
    |> message_struct(author, reply_to, [])
    |> Message.changeset(%{number: number, kind: kind, body: body})
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

  defp fetch_message(thread, ref) do
    with {:ok, number} <- parse_message_ref(thread, ref),
         %Message{} = message <-
           Message
           |> where(thread_id: ^thread.id, number: ^number)
           |> preload([:author_agent, :to_agent, :claimed_by_agent])
           |> Repo.one() do
      {:ok, message}
    else
      {:error, _} = error ->
        error

      nil ->
        {:error,
         {:invalid,
          "No message #{message_ref(thread.number, ref_number(ref))} in #{thread_ref(thread)}",
          %{message: ref}}}
    end
  end

  # The requests a response from `me` resolves.
  defp resolvable!(thread, me, nil) do
    thread |> addressed_requests(me) |> Enum.reject(&held_by_other?(&1, me))
  end

  defp resolvable!(_thread, _me, %Message{kind: kind}) when kind != :request, do: []

  defp resolvable!(thread, me, %Message{} = request), do: [actionable!(thread, me, request)]

  defp claimable_request!(thread, me, ref) do
    case fetch_message(thread, ref) do
      {:ok, %Message{kind: :request} = request} ->
        actionable!(thread, me, request)

      {:ok, message} ->
        ref = message_ref(thread, message)
        Repo.rollback({:invalid, "#{ref} is not a request", %{request_id: ref}})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # A request `me` may claim or answer right now, or a rollback that says why not.
  defp actionable!(thread, me, request) do
    ref = message_ref(thread, request)

    cond do
      request.request_state not in @pending ->
        Repo.rollback({:conflict, "#{ref} is already #{request.request_state}", %{request: ref}})

      not addressed_to?(request, me) ->
        Repo.rollback({:forbidden, "#{ref} is not addressed to you"})

      held_by_other?(request, me) ->
        Repo.rollback(
          {:conflict, "#{ref} is claimed by #{request.claimed_by_agent.name}",
           %{claimed_by: Map.new([holder(thread, request)])}}
        )

      true ->
        request
    end
  end

  defp cancellable_request!(thread, me, ref) do
    case fetch_message(thread, ref) do
      {:ok, %Message{kind: :request} = request} ->
        ref = message_ref(thread, request)

        cond do
          me.id not in [request.author_agent_id, thread.opened_by_agent_id] ->
            Repo.rollback(
              {:forbidden,
               "Only the author of #{ref} or the agent that opened #{thread_ref(thread)} can cancel it"}
            )

          request.request_state not in @pending ->
            Repo.rollback(
              {:conflict, "#{ref} is already #{request.request_state}", %{request: ref}}
            )

          true ->
            request
        end

      {:ok, message} ->
        ref = message_ref(thread, message)
        Repo.rollback({:invalid, "#{ref} is not a request", %{request_id: ref}})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp to_name(%Message{to_agent: %Agent{name: name}}), do: name
  defp to_name(%Message{}), do: nil

  defp require_request_id(nil),
    do: {:error, {:invalid, "request_id is required", %{request_id: ["can't be blank"]}}}

  defp require_request_id(ref), do: {:ok, ref}

  defp check_reason(nil), do: :ok
  defp check_reason(reason) when is_binary(reason), do: check_body_size(reason)

  defp check_reason(_reason),
    do: {:error, {:invalid, "reason must be a string", %{reason: ["must be a string"]}}}

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  # Pending requests of the thread addressed to `me`, whoever holds them.
  defp addressed_requests(thread, me) do
    Message
    |> where(
      [m],
      m.thread_id == ^thread.id and m.kind == :request and m.request_state in ^@pending
    )
    |> where(^addressed_to(me))
    |> order_by(:number)
    |> preload(:claimed_by_agent)
    |> Repo.all()
  end

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

  defp addressed_to(%Agent{id: me, label: label}) do
    named_or_any =
      dynamic([m], m.to_agent_id == ^me or (m.to_target == :any and m.author_agent_id != ^me))

    if label,
      do: dynamic([m], ^named_or_any or (m.to_target == :label and m.to_label == ^label)),
      else: named_or_any
  end

  defp addressed_to?(%Message{to_target: :agent, to_agent_id: id}, %Agent{id: me}), do: id == me

  defp addressed_to?(%Message{to_target: :label, to_label: l}, %Agent{label: label}),
    do: l == label

  defp addressed_to?(%Message{to_target: :any, author_agent_id: a}, %Agent{id: me}), do: a != me

  defp held_by_other?(%Message{request_state: :claimed, claimed_by_agent_id: id}, %Agent{id: me}),
    do: id != me

  defp held_by_other?(%Message{}, _me), do: false

  defp holder(thread, %Message{claimed_by_agent: %Agent{name: name}} = request),
    do: {message_ref(thread, request), name}

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

  defp check_opened_by!(%Thread{opened_by_agent_id: id}, %Agent{id: id}), do: :ok

  defp check_opened_by!(thread, _me) do
    Repo.rollback({:forbidden, "Only the agent that opened #{thread_ref(thread)} can do that"})
  end

  defp rollback_finished(thread) do
    ref = thread_ref(thread)
    Repo.rollback({:conflict, "#{ref} is finished; reopen it first", %{thread: ref}})
  end

  defp targets_for(:request, to, author), do: Targets.resolve(to, author)
  defp targets_for(_kind, nil, _author), do: {:ok, []}

  defp targets_for(_kind, _to, _author),
    do: {:error, {:invalid, "Only a request has a to", %{to: ["only for requests"]}}}

  defp parse_kind(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, kind} ->
        {:ok, kind}

      :error ->
        {:error, {:invalid, "kind must be request, response or note", %{kind: [inspect(kind)]}}}
    end
  end

  defp check_body_size(body) when is_binary(body) do
    max = Message.max_body_bytes()

    if byte_size(body) > max,
      do: {:error, {:too_large, "The body is over #{max} bytes"}},
      else: :ok
  end

  defp check_body_size(_body), do: :ok

  ## Parsing readable ids

  @doc "The number of a thread ref: `\"T3\"` (any case) → `{:ok, 3}`."
  def parse_thread_ref(ref) when is_binary(ref) do
    case Regex.run(~r/^[Tt]([1-9][0-9]{0,9})$/, String.trim(ref)) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> :error
    end
  end

  def parse_thread_ref(_ref), do: :error

  @doc """
  The number of a message of `thread`: `"T3.5"`, `"5"` or `5`. A ref of another thread is
  `{:error, {:invalid, …}}`.
  """
  def parse_message_ref(%Thread{number: thread}, ref) do
    case ref_parts(ref) do
      {nil, number} ->
        {:ok, number}

      {^thread, number} ->
        {:ok, number}

      {_other, _number} ->
        {:error, {:invalid, "#{ref} is not a message of T#{thread}", %{message: ref}}}

      :error ->
        {:error,
         {:invalid, "#{inspect(ref)} is not a message id like T#{thread}.2", %{message: ref}}}
    end
  end

  defp ref_parts(n) when is_integer(n) and n > 0, do: {nil, n}

  defp ref_parts(ref) when is_binary(ref) do
    case Regex.run(~r/^(?:[Tt]([1-9][0-9]{0,9})\.)?([1-9][0-9]{0,9})$/, String.trim(ref)) do
      [_, "", m] -> {nil, String.to_integer(m)}
      [_, t, m] -> {String.to_integer(t), String.to_integer(m)}
      nil -> :error
    end
  end

  defp ref_parts(_ref), do: :error

  defp ref_number(ref) do
    case ref_parts(ref) do
      {_, n} -> n
      :error -> ref
    end
  end

  ## Query filters

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: where(query, status: ^status)

  defp filter_awaiting(query, nil), do: query

  defp filter_awaiting(query, %Agent{} = me) do
    open =
      Message
      |> where([m], m.kind == :request and m.request_state == :open)
      |> where(^addressed_to(me))
      |> select([m], m.thread_id)

    where(query, [t], t.id in subquery(open))
  end

  defp filter_since(query, nil), do: query
  defp filter_since(query, number), do: where(query, [m], m.number > ^number)

  # An event payload names the files of the post, when it has any.
  defp with_attachments(payload, []), do: payload

  defp with_attachments(payload, files),
    do: Map.put(payload, :attachments, Enum.map(files, & &1.filename))

  defp session(%Thread{session_id: id}), do: %Session{id: id}

  defp rollback_on_error({:ok, record}), do: record
  defp rollback_on_error({:error, changeset}), do: Repo.rollback(changeset)

  defp now, do: DateTime.utc_now()
end
