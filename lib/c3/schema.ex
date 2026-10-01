defmodule C3.Schema do
  @moduledoc """
  Shared setup for every C3 schema: `Ecto.Schema`, `Ecto.Changeset` and microsecond UTC
  timestamps, as `schema.md` prescribes.

  On SQLite a foreign key violation carries no constraint name, so `foreign_key_constraint/3`
  cannot turn it into a changeset error and `Repo` raises `Ecto.ConstraintError` instead. The
  calls are kept so the mapping works as is on Postgres; foreign keys are always set from
  records the caller already loaded.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset
      import C3.Schema, only: [validate_present_iff: 4]

      @timestamps_opts [type: :utc_datetime_usec]
    end
  end

  @doc """
  Mirrors a conditional `CHECK` of the form `(field IS NOT NULL) = condition`: `field` must be
  set exactly when `condition?` holds for the changeset, and `message` explains the rule.
  """
  def validate_present_iff(changeset, field, condition?, message) do
    present? = not is_nil(Ecto.Changeset.get_field(changeset, field))

    cond do
      present? == condition?.(changeset) -> changeset
      present? -> Ecto.Changeset.add_error(changeset, field, "must be blank " <> message)
      true -> Ecto.Changeset.add_error(changeset, field, "must be set " <> message)
    end
  end
end
