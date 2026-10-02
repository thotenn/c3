defmodule C3.Threads.Guards do
  @moduledoc """
  The checks of the writes in `C3.Threads`. The `!` ones run inside its transaction and roll
  it back with the reason; the rest return `:ok`/`{:ok, value}` or `{:error, reason}` before
  the transaction starts. Internal to `C3.Threads`.
  """
  import C3.Threads.Refs
  import C3.Threads.Queries, only: [addressed_requests: 2, fetch_message: 2]

  alias C3.Repo
  alias C3.Sessions.Agent
  alias C3.Threads.{Message, Targets, Thread}

  @kinds %{"request" => :request, "response" => :response, "note" => :note}
  @pending [:open, :claimed]

  @doc false
  # The requests a response from `me` resolves.
  def resolvable!(thread, me, nil) do
    thread |> addressed_requests(me) |> Enum.reject(&held_by_other?(&1, me))
  end

  def resolvable!(_thread, _me, %Message{kind: kind}) when kind != :request, do: []

  def resolvable!(thread, me, %Message{} = request), do: [actionable!(thread, me, request)]

  @doc false
  def claimable_request!(thread, me, ref) do
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

  @doc false
  # A request `me` may claim or answer right now, or a rollback that says why not.
  def actionable!(thread, me, request) do
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

  @doc false
  def cancellable_request!(thread, me, ref) do
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

  @doc false
  def require_request_id(nil),
    do: {:error, {:invalid, "request_id is required", %{request_id: ["can't be blank"]}}}

  def require_request_id(ref), do: {:ok, ref}

  @doc false
  def check_reason(nil), do: :ok
  def check_reason(reason) when is_binary(reason), do: check_body_size(reason)

  def check_reason(_reason),
    do: {:error, {:invalid, "reason must be a string", %{reason: ["must be a string"]}}}

  @doc false
  def addressed_to?(%Message{to_target: :agent, to_agent_id: id}, %Agent{id: me}), do: id == me

  def addressed_to?(%Message{to_target: :label, to_label: l}, %Agent{label: label}),
    do: l == label

  def addressed_to?(%Message{to_target: :any, author_agent_id: a}, %Agent{id: me}), do: a != me

  @doc false
  def held_by_other?(%Message{request_state: :claimed, claimed_by_agent_id: id}, %Agent{id: me}),
    do: id != me

  def held_by_other?(%Message{}, _me), do: false

  @doc false
  def holder(thread, %Message{claimed_by_agent: %Agent{name: name}} = request),
    do: {message_ref(thread, request), name}

  @doc false
  def check_opened_by!(%Thread{opened_by_agent_id: id}, %Agent{id: id}), do: :ok

  def check_opened_by!(thread, _me) do
    Repo.rollback({:forbidden, "Only the agent that opened #{thread_ref(thread)} can do that"})
  end

  @doc false
  def rollback_finished(thread) do
    ref = thread_ref(thread)
    Repo.rollback({:conflict, "#{ref} is finished; reopen it first", %{thread: ref}})
  end

  @doc false
  def targets_for(:request, to, author), do: Targets.resolve(to, author)
  def targets_for(_kind, nil, _author), do: {:ok, []}

  def targets_for(_kind, _to, _author),
    do: {:error, {:invalid, "Only a request has a to", %{to: ["only for requests"]}}}

  @doc false
  def parse_kind(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, kind} ->
        {:ok, kind}

      :error ->
        {:error, {:invalid, "kind must be request, response or note", %{kind: [inspect(kind)]}}}
    end
  end

  @doc false
  def check_body_size(body) when is_binary(body) do
    max = Message.max_body_bytes()

    if byte_size(body) > max,
      do: {:error, {:too_large, "The body is over #{max} bytes"}},
      else: :ok
  end

  def check_body_size(_body), do: :ok
end
