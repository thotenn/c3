defmodule C3.Repo.Migrations.AddRequestCancelledEvent do
  use Ecto.Migration

  # Adds request.cancelled to events_type_check. SQLite cannot alter a CHECK, so the table is
  # rebuilt: create the new one, copy the rows, drop the old one, rename. Nothing references
  # events, so no foreign key has to move. The same steps work on Postgres.

  @base ~w(
    agent.joined agent.left agent.revoked
    thread.opened message.posted thread.status_changed
    request.claimed request.claim_expired
    security.join_failed session.joins_locked session.joins_unlocked
    session.closing_soon session.closed
  )

  @columns ~w(id session_id seq type actor_agent_id thread_id message_id payload inserted_at)

  def up, do: rebuild(@base ++ ["request.cancelled"])

  def down do
    execute "DELETE FROM events WHERE type = 'request.cancelled'"
    rebuild(@base)
  end

  defp rebuild(types) do
    create table(:events_new) do
      add :session_id,
          references(:sessions, on_delete: :delete_all, name: :events_session_id_fkey),
          null: false

      add :seq, :integer, null: false

      add :type, :text,
        null: false,
        check: %{name: "events_type_check", expr: "type IN (#{sql_list(types)})"}

      # Named as the original table names them, not after events_new.
      add :actor_agent_id, references(:agents, name: :events_actor_agent_id_fkey)
      add :thread_id, references(:threads, name: :events_thread_id_fkey)
      add :message_id, references(:messages, name: :events_message_id_fkey)
      add :payload, :text, null: false, default: "{}"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    columns = Enum.join(@columns, ", ")
    execute "INSERT INTO events_new (#{columns}) SELECT #{columns} FROM events"
    drop table(:events)
    rename table(:events_new), to: table(:events)
    create unique_index(:events, [:session_id, :seq])
  end

  defp sql_list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
