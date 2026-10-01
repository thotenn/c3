defmodule C3.Security do
  @moduledoc """
  Failed joins and IP bans.

  Read-only for now: recording failures, banning and the ETS mirror of the active bans land
  in F2.
  """
  import Ecto.Query

  alias C3.Repo
  alias C3.Security.IpBan

  @doc "The bans in force at `now`: not expired and not lifted."
  def list_active_bans(now \\ DateTime.utc_now()) do
    IpBan
    |> where([b], b.banned_until > ^now and is_nil(b.lifted_at))
    |> order_by(:banned_until)
    |> Repo.all()
  end
end
