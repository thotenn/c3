defmodule C3.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  @types ~w(
    agent.joined agent.left agent.revoked
    thread.opened message.posted thread.status_changed
    request.claimed request.claim_expired
    security.join_failed session.joins_locked session.joins_unlocked
    session.closing_soon session.closed
  )

  def change do
    create table(:events) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :seq, :integer, null: false

      add :type, :text,
        null: false,
        check: %{name: "events_type_check", expr: "type IN (#{sql_list(@types)})"}

      add :actor_agent_id, references(:agents)
      add :thread_id, references(:threads)
      add :message_id, references(:messages)
      add :payload, :text, null: false, default: "{}"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:events, [:session_id, :seq])
  end

  defp sql_list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
