defmodule C3.Threads.Derivation do
  @moduledoc """
  The thread state machine of the spec (*Máquina de estados del hilo*), as a pure function of
  the thread's requests. The rules apply in this order:

    1. `finished` if `opened_by` finished it (and did not reopen it).
    2. `pending` if any request is `open` — `awaiting` is the union of their targets.
    3. `processing` if any request is `claimed` — `processing_by` is who claimed them.
    4. `answered` otherwise.

  `awaiting` and `processing_by` are always computed: a `pending` thread can also have
  claimed requests in progress. Both keep the order of the requests and never repeat.
  """

  @type request :: %{
          required(:state) => :open | :claimed | :done | :cancelled,
          required(:to) => String.t(),
          required(:claimed_by) => String.t() | nil
        }

  @type t :: %{
          status: :pending | :processing | :answered | :finished,
          awaiting: [String.t()],
          processing_by: [String.t()]
        }

  @doc "The derived state of a thread, given whether it is finished and its requests in order."
  @spec derive(boolean(), [request()]) :: t()
  def derive(finished?, requests) when is_boolean(finished?) do
    awaiting = for %{state: :open, to: to} <- requests, uniq: true, do: to
    processing_by = for %{state: :claimed, claimed_by: by} <- requests, uniq: true, do: by

    status =
      cond do
        finished? -> :finished
        awaiting != [] -> :pending
        processing_by != [] -> :processing
        true -> :answered
      end

    %{status: status, awaiting: awaiting, processing_by: processing_by}
  end
end
