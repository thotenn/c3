defmodule C3.Repo.Migrations.CreateJoinFailures do
  use Ecto.Migration

  def change do
    create table(:join_failures) do
      add :ip, :text, null: false

      add :reason, :text,
        null: false,
        check: %{
          name: "join_failures_reason_check",
          expr: "reason IN ('invalid_secret','unknown_code','session_closed','joins_locked')"
        }

      add :session_id, references(:sessions, on_delete: :nilify_all)
      add :attempted_code, :text, null: false
      add :attempted_label, :text
      add :user_agent, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:join_failures, [:ip, :inserted_at])
    create index(:join_failures, [:session_id, :reason, :ip])
  end
end
