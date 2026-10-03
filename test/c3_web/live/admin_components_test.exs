defmodule C3Web.Admin.ComponentsTest do
  use ExUnit.Case, async: true

  alias C3.Events.Event
  alias C3Web.Admin.Components

  # A new event type without a summary would crash the session page of the admin.
  test "every event type has a summary, even with an empty payload" do
    for type <- Ecto.Enum.values(Event, :type) do
      assert is_binary(Components.event_summary(%Event{type: type, payload: %{}})),
             "no summary for #{type}"
    end
  end
end
