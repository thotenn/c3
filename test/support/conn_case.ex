defmodule C3Web.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use C3Web.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint C3Web.Endpoint

      use C3Web, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import C3Web.ConnCase
    end
  end

  setup tags do
    C3.DataCase.setup_sandbox(tags)
    {:ok, conn: with_ip(Phoenix.ConnTest.build_conn(), unique_ip())}
  end

  @doc """
  A fresh client IP from 198.18.0.0/15 (benchmarking range). Bans live in a global ETS
  table, so every test gets its own address and one test's ban never blocks another.
  """
  def unique_ip do
    n = System.unique_integer([:positive])
    {198, 18 + rem(div(n, 65_536), 2), rem(div(n, 256), 256), rem(n, 256)}
  end

  @doc "The same connection, coming from `ip` (a tuple)."
  def with_ip(conn, ip), do: %{conn | remote_ip: ip}

  @doc "The string form of an IP tuple, as C3 stores it."
  def ip_string(ip), do: ip |> :inet.ntoa() |> List.to_string()
end
