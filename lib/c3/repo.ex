defmodule C3.Repo do
  use Ecto.Repo,
    otp_app: :c3,
    adapter: Ecto.Adapters.SQLite3
end
