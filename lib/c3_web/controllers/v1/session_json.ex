defmodule C3Web.V1.SessionJSON do
  @moduledoc """
  JSON for `/v1/sessions`. Internal ids never leave: agents are `AGn` and threads `Tn`. The
  clear secret and token appear only in `created` and `joined`.
  """
  alias C3.Sessions.{Agent, Session}

  def created(%{session: session, agent: agent, secret: secret, token: token}) do
    %{
      session_code: session.code,
      secret: secret,
      agent: agent(agent, token),
      expires_at: session.expires_at
    }
  end

  def joined(%{session: session, agent: agent, token: token}) do
    %{session_code: session.code, agent: agent(agent, token), expires_at: session.expires_at}
  end

  def show(%{session: session, you: you, agents: agents, threads: threads}) do
    %{
      session: session(session),
      you: you.name,
      agents: Enum.map(agents, &agent/1),
      threads:
        Enum.map(threads, fn thread ->
          %{
            id: "T#{thread.number}",
            title: thread.title,
            status: thread.status,
            opened_by: thread.opened_by_agent.name,
            last_message_at: thread.last_message_at
          }
        end)
    }
  end

  defp session(%Session{} = s) do
    %{
      code: s.code,
      label: s.label,
      status: s.status,
      joins_locked: not is_nil(s.joins_locked_at),
      created_at: s.inserted_at,
      last_activity_at: s.last_activity_at,
      expires_at: s.expires_at
    }
  end

  defp agent(%Agent{} = a, token), do: %{name: a.name, label: a.label, token: token}

  defp agent(%Agent{} = a) do
    %{
      name: a.name,
      label: a.label,
      status: a.status,
      joined_at: a.inserted_at,
      last_seen_at: a.last_seen_at
    }
  end
end
