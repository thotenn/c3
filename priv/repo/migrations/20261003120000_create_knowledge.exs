defmodule C3.Repo.Migrations.CreateKnowledge do
  use Ecto.Migration

  # The shared memory of a session (C3-2): `K<n>` entries numbered per session, like threads.

  def change do
    alter table(:sessions) do
      add :next_knowledge_number, :integer, null: false, default: 1
    end

    create table(:knowledge) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :topic, :text, null: false

      add :kind, :text,
        null: false,
        check: %{
          name: "knowledge_kind_check",
          expr: "kind IN ('decision','fact','constraint','todo')"
        }

      add :summary, :text, null: false
      add :author_agent_id, references(:agents), null: false
      add :source, :text

      add :status, :text,
        null: false,
        default: "active",
        check: %{
          name: "knowledge_status_check",
          expr: "status IN ('active','superseded','retracted')"
        }

      add :supersedes_id, references(:knowledge)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:knowledge, [:session_id, :number])
    create index(:knowledge, [:session_id, :topic, :status])
  end
end
