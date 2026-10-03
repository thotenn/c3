defmodule C3.Repo.Migrations.CreateReservations do
  use Ecto.Migration

  # Advisory reservations of a session (C3-4): `R<n>` leases on an opaque pattern, numbered per
  # session like threads and knowledge entries.

  def change do
    alter table(:sessions) do
      add :next_reservation_number, :integer, null: false, default: 1
    end

    create table(:reservations) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :agent_id, references(:agents), null: false
      add :number, :integer, null: false
      add :pattern, :text, null: false
      add :exclusive, :boolean, null: false, default: true
      add :reason, :text
      add :expires_at, :utc_datetime_usec, null: false
      add :released_at, :utc_datetime_usec

      add :release_reason, :text,
        check: %{
          name: "reservations_release_reason_check",
          expr:
            "(release_reason IS NULL OR " <>
              "release_reason IN ('released','expired','left','revoked','session_closed')) " <>
              "AND (release_reason IS NULL) = (released_at IS NULL)"
        }

      add :waiters, {:array, :text}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:reservations, [:session_id, :number])
    create index(:reservations, [:session_id, :released_at])
    create index(:reservations, [:agent_id, :released_at])
  end
end
