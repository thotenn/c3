defmodule C3.Security.IpBan do
  @moduledoc """
  A ban of an IP for `create`/`join` until `banned_until`. The table is the source of
  truth; the active bans are mirrored into ETS (F2). See `schema.md` §7.
  """
  use C3.Schema

  schema "ip_bans" do
    field :ip, :string
    field :ip_full, :string
    field :reason, Ecto.Enum, values: [:invalid_secret, :unknown_code, :admin]
    field :session_code, :string
    field :banned_until, :utc_datetime_usec
    field :lifted_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  @fields ~w(ip ip_full reason session_code banned_until lifted_at)a

  def changeset(ip_ban, attrs) do
    ip_ban
    |> cast(attrs, @fields)
    |> validate_required([:ip, :reason, :banned_until])
    |> check_constraint(:reason, name: :ip_bans_reason_check)
  end
end
