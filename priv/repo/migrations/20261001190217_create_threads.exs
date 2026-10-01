defmodule C3.Repo.Migrations.CreateThreads do
  use Ecto.Migration

  def change do
    create table(:threads) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :title, :text, null: false
      add :opened_by_agent_id, references(:agents), null: false

      add :status, :text,
        null: false,
        default: "pending",
        check: %{
          name: "threads_status_check",
          expr: "status IN ('pending','processing','answered','finished')"
        }

      add :finished_at, :utc_datetime_usec,
        check: %{
          name: "threads_finished_at_check",
          expr: "(finished_at IS NOT NULL) = (status = 'finished')"
        }

      add :last_message_at, :utc_datetime_usec, null: false
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:threads, [:session_id, :number])
    create index(:threads, [:session_id, :status])
    create index(:threads, [:session_id, :last_message_at])
  end
end
