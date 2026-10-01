defmodule C3.Repo.Migrations.CreateIdempotencyKeys do
  use Ecto.Migration

  def change do
    create table(:idempotency_keys) do
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :request_hash, :text, null: false
      add :response_status, :integer, null: false
      add :response_body, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:idempotency_keys, [:agent_id, :key])
    create index(:idempotency_keys, [:inserted_at])
  end
end
