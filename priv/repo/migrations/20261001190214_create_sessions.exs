defmodule C3.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :code, :text, null: false
      add :secret_hash, :text, null: false
      add :label, :text

      add :status, :text,
        null: false,
        default: "open",
        check: %{name: "sessions_status_check", expr: "status IN ('open','closed')"}

      add :joins_locked_at, :utc_datetime_usec
      add :next_agent_number, :integer, null: false, default: 1
      add :next_thread_number, :integer, null: false, default: 1
      add :event_seq, :integer, null: false, default: 0
      add :last_activity_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      add :closed_at, :utc_datetime_usec,
        check: %{
          name: "sessions_closed_at_check",
          expr: "(closed_at IS NOT NULL) = (status = 'closed')"
        }

      add :closed_by, :text

      add :close_reason, :text,
        check: %{
          name: "sessions_close_reason_check",
          expr: "close_reason IN ('manual','idle','max_ttl','admin')"
        }

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sessions, [:code])
    create index(:sessions, [:status, :last_activity_at])
    create index(:sessions, [:status, :expires_at])
    create index(:sessions, [:status, :closed_at])
  end
end
