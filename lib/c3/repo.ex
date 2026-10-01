defmodule C3.Repo do
  @moduledoc """
  The repo. `transaction/2` is wrapped so that the events appended inside it
  (`C3.Events.append!/3`) are published to their sessions only once the outermost transaction
  commits: a rollback notifies nothing, and no context has to know about PubSub.
  """
  use Ecto.Repo,
    otp_app: :c3,
    adapter: Ecto.Adapters.SQLite3

  defoverridable transaction: 1, transaction: 2

  def transaction(fun_or_multi, opts \\ []) do
    if in_transaction?() do
      super(fun_or_multi, opts)
    else
      C3.Events.publish_after(fn -> super(fun_or_multi, opts) end)
    end
  end
end
