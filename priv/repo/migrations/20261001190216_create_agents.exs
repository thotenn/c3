defmodule C3.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :name, :text, null: false
      add :label, :text
      add :token_hash, :text, null: false

      add :status, :text,
        null: false,
        default: "active",
        check: %{name: "agents_status_check", expr: "status IN ('active','left','revoked')"}

      add :alerts_seen_seq, :integer, null: false, default: 0
      add :joined_ip, :text, null: false
      add :user_agent, :text
      add :last_seen_at, :utc_datetime_usec, null: false
      add :left_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:session_id, :number])
    create unique_index(:agents, [:session_id, :name])
    create unique_index(:agents, [:token_hash])
    create index(:agents, [:session_id, :label])
  end
end
