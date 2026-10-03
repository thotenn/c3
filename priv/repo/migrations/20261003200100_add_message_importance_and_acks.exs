defmodule C3.Repo.Migrations.AddMessageImportanceAndAcks do
  use Ecto.Migration

  # Importance and acknowledgements of a message (C3-4). A row of `message_acks` is one
  # recipient asked to acknowledge; `acked_at` stays NULL until it does.

  def change do
    alter table(:messages) do
      add :importance, :text,
        null: false,
        default: "normal",
        check: %{
          name: "messages_importance_check",
          expr: "importance IN ('normal','high','urgent')"
        }

      add :ack_required, :boolean, null: false, default: false
    end

    create table(:message_acks) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :agent_id, references(:agents), null: false
      add :acked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:message_acks, [:message_id, :agent_id])
    create index(:message_acks, [:agent_id, :acked_at])
  end
end
