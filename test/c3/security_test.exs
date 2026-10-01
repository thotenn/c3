defmodule C3.SecurityTest do
  use C3.DataCase

  import C3.Fixtures

  alias C3.Security
  alias C3.Security.{IpBan, JoinFailure}

  describe "JoinFailure.changeset/2" do
    test "valid with or without a session" do
      assert %JoinFailure{session_id: id} = join_failure_fixture(session_fixture())
      assert id
      assert %JoinFailure{session_id: nil} = join_failure_fixture(nil, %{reason: :unknown_code})
    end

    test "requires ip, reason and code; limits the code" do
      errors = errors_on(JoinFailure.changeset(%JoinFailure{}, %{}))
      assert errors.ip && errors.reason && errors.attempted_code

      cs = JoinFailure.changeset(%JoinFailure{}, %{attempted_code: String.duplicate("C", 33)})
      assert "should be at most 32 character(s)" in errors_on(cs).attempted_code

      assert "is invalid" in errors_on(JoinFailure.changeset(%JoinFailure{}, %{reason: "x"})).reason
    end
  end

  describe "IpBan.changeset/2" do
    test "requires ip, reason and banned_until" do
      errors = errors_on(IpBan.changeset(%IpBan{}, %{}))
      assert errors.ip && errors.reason && errors.banned_until

      assert "is invalid" in errors_on(IpBan.changeset(%IpBan{}, %{reason: :session_closed})).reason
    end
  end

  test "list_active_bans/1 skips expired and lifted bans" do
    now = DateTime.utc_now()
    active = ip_ban_fixture(%{ip: "198.51.100.1"})
    ip_ban_fixture(%{ip: "198.51.100.2", banned_until: DateTime.add(now, -1)})
    ip_ban_fixture(%{ip: "198.51.100.3", lifted_at: now})

    assert Enum.map(Security.list_active_bans(now), & &1.id) == [active.id]
    assert Security.list_active_bans(DateTime.add(now, 7200)) == []
  end
end
