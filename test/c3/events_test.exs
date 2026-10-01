defmodule C3.EventsTest do
  use C3.DataCase, async: true

  import C3.Fixtures

  alias C3.Events
  alias C3.Events.Event

  setup do
    %{session: session_fixture()}
  end

  test "stores the dotted type and a JSON payload", %{session: session} do
    event =
      event_fixture(session, %{
        seq: 1,
        type: :security_join_failed,
        payload: %{ip: "198.51.100.1"}
      })

    assert Repo.reload!(event).payload == %{"ip" => "198.51.100.1"}

    assert Repo.query!("SELECT type FROM events WHERE id = ?", [event.id]).rows ==
             [["security.join_failed"]]
  end

  test "payload defaults to an empty map", %{session: session} do
    assert event_fixture(session).payload == %{}
  end

  test "type and seq are required, seq starts at 1" do
    errors = errors_on(Event.changeset(%Event{}, %{}))
    assert errors.type
    assert errors.seq
    assert errors_on(Event.changeset(%Event{}, %{seq: 0})).seq
    assert "is invalid" in errors_on(Event.changeset(%Event{}, %{type: "agent.bogus"})).type
    assert get_field(Event.changeset(%Event{}, %{type: "agent.joined"}), :type) == :agent_joined
  end

  test "seq is unique per session", %{session: session} do
    event_fixture(session, %{seq: 1})

    assert {:error, cs} =
             %Event{session_id: session.id}
             |> Event.changeset(%{seq: 1, type: :agent_left})
             |> Repo.insert()

    assert "has already been taken" in errors_on(cs).session_id
    assert event_fixture(session_fixture(), %{seq: 1})
  end

  test "list_after/3 returns later events in order, limited", %{session: session} do
    for seq <- [3, 1, 2], do: event_fixture(session, %{seq: seq})
    event_fixture(session_fixture(), %{seq: 2})

    assert Enum.map(Events.list_after(session, 0), & &1.seq) == [1, 2, 3]
    assert Enum.map(Events.list_after(session, 1), & &1.seq) == [2, 3]
    assert Enum.map(Events.list_after(session, 0, limit: 2), & &1.seq) == [1, 2]
    assert Events.list_after(session, 3) == []
  end
end
