defmodule C3.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  # SQLite takes one CHECK per column here, so the conditional rules of schema.md are
  # attached to the column they constrain. NULLs are folded with COALESCE so that a
  # comparison against NULL never lets a row through.
  def change do
    create table(:messages) do
      add :thread_id, references(:threads, on_delete: :delete_all), null: false
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :number, :integer, null: false

      add :kind, :text,
        null: false,
        check: %{
          name: "messages_kind_check",
          expr: "kind IN ('request','response','note','system')"
        }

      add :author_agent_id, references(:agents),
        check: %{
          name: "messages_author_check",
          expr: "(author_agent_id IS NULL) = (kind = 'system')"
        }

      add :body, :text, null: false

      add :to_target, :text,
        check: %{
          name: "messages_to_target_check",
          expr:
            "(to_target IS NULL OR to_target IN ('agent','label','any')) " <>
              "AND (to_target IS NOT NULL) = (kind = 'request')"
        }

      add :to_agent_id, references(:agents),
        check: %{
          name: "messages_to_agent_check",
          expr: "(to_agent_id IS NOT NULL) = (COALESCE(to_target, '') = 'agent')"
        }

      add :to_label, :text,
        check: %{
          name: "messages_to_label_check",
          expr: "(to_label IS NOT NULL) = (COALESCE(to_target, '') = 'label')"
        }

      add :reply_to_message_id, references(:messages)

      add :request_state, :text,
        check: %{
          name: "messages_request_state_check",
          expr:
            "(request_state IS NULL OR request_state IN ('open','claimed','done','cancelled')) " <>
              "AND (request_state IS NOT NULL) = (kind = 'request')"
        }

      # claimed => set; done => set or not (depends on whether it went through a claim);
      # open, cancelled and non-requests => unset.
      add :claimed_by_agent_id, references(:agents),
        check: %{
          name: "messages_claimed_by_check",
          expr:
            "CASE COALESCE(request_state, '') " <>
              "WHEN 'claimed' THEN claimed_by_agent_id IS NOT NULL " <>
              "WHEN 'done' THEN 1 = 1 " <>
              "ELSE claimed_by_agent_id IS NULL END"
        }

      add :claimed_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:messages, [:thread_id, :number])
    create index(:messages, [:session_id, :kind, :request_state])
    create index(:messages, [:to_agent_id, :request_state])
    create index(:messages, [:session_id, :to_label])
    create index(:messages, [:reply_to_message_id])
    create index(:messages, [:claimed_by_agent_id, :request_state])
  end
end
