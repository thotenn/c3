defmodule C3Web.V1.ReservationJSON do
  @moduledoc """
  JSON for reservations. Only readable ids leave: reservations `R3`, agents `AG2`. `status`
  is derived: `active`, or why it ended (`released`, `expired`, `left`, `revoked`,
  `session_closed`) — an expired one the sweeper has not recorded yet reads `expired`.
  """
  alias C3.Reservations
  alias C3.Reservations.Reservation

  def index(%{reservations: reservations}),
    do: %{reservations: Enum.map(reservations, &reservation/1)}

  @doc "One reservation."
  def reservation(%Reservation{} = r) do
    %{
      id: Reservations.reservation_ref(r),
      pattern: r.pattern,
      exclusive: r.exclusive,
      agent: r.agent.name,
      reason: r.reason,
      status: status(r),
      expires_at: r.expires_at,
      released_at: r.released_at,
      waiters: r.waiters,
      created_at: r.inserted_at
    }
  end

  defp status(%Reservation{release_reason: nil} = r) do
    if Reservations.active?(r, DateTime.utc_now()), do: :active, else: :expired
  end

  defp status(%Reservation{release_reason: reason}), do: reason
end
