defmodule C3.Repo.Migrations.CreateAttachments do
  use Ecto.Migration

  # schema.md §9. The content lives on disk under the attachments directory; a row per message
  # that carries it (a request to several targets is one message per target, all pointing at
  # the same file: `storage_key` is not unique).
  def change do
    create table(:attachments) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :filename, :text, null: false
      add :content_type, :text, null: false

      add :size_bytes, :integer,
        null: false,
        check: %{name: "attachments_size_check", expr: "size_bytes >= 0"}

      add :sha256, :text, null: false
      add :storage_key, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:attachments, [:message_id])
    create index(:attachments, [:session_id, :storage_key])
  end
end
