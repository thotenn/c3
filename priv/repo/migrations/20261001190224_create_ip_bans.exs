defmodule C3.Repo.Migrations.CreateIpBans do
  use Ecto.Migration

  def change do
    create table(:ip_bans) do
      add :ip, :text, null: false

      add :reason, :text,
        null: false,
        check: %{
          name: "ip_bans_reason_check",
          expr: "reason IN ('invalid_secret','unknown_code','admin')"
        }

      add :session_code, :text
      add :banned_until, :utc_datetime_usec, null: false
      add :lifted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:ip_bans, [:ip, :banned_until])
  end
end
