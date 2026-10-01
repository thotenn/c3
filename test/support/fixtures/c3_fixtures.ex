defmodule C3.Fixtures do
  @moduledoc """
  Builders for the C3 schemas, inserted through their changesets. Each takes the parents it
  belongs to and a map of overrides.
  """
  alias C3.Events.Event
  alias C3.Repo
  alias C3.Security.{IpBan, JoinFailure}
  alias C3.Sessions.{Agent, IdempotencyKey, Session}
  alias C3.Threads.{Message, Thread}

  def unique_int, do: System.unique_integer([:positive])

  def session_fixture(attrs \\ %{}) do
    %Session{}
    |> Session.changeset(
      Enum.into(attrs, %{
        code: "C3-#{unique_int()}",
        secret_hash: "hash",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })
    )
    |> Repo.insert!()
  end

  def agent_fixture(%Session{} = session, attrs \\ %{}) do
    number = attrs[:number] || unique_int()

    %Agent{session_id: session.id}
    |> Agent.changeset(
      Enum.into(attrs, %{
        number: number,
        name: "AG#{number}",
        token_hash: "token-#{unique_int()}",
        joined_ip: "203.0.113.7"
      })
    )
    |> Repo.insert!()
  end

  def thread_fixture(%Agent{} = opened_by, attrs \\ %{}) do
    %Thread{session_id: opened_by.session_id, opened_by_agent_id: opened_by.id}
    |> Thread.changeset(Enum.into(attrs, %{number: unique_int(), title: "A thread"}))
    |> Repo.insert!()
  end

  @doc "A request from `author` to the agent `to`, open."
  def request_fixture(%Thread{} = thread, %Agent{} = author, %Agent{} = to, attrs \\ %{}) do
    thread
    |> message_struct(author, to_agent_id: to.id)
    |> Message.changeset(
      Enum.into(attrs, %{
        number: unique_int(),
        kind: :request,
        body: "Please do it",
        to_target: :agent,
        request_state: :open
      })
    )
    |> Repo.insert!()
  end

  def note_fixture(%Thread{} = thread, %Agent{} = author, attrs \\ %{}) do
    thread
    |> message_struct(author)
    |> Message.changeset(Enum.into(attrs, %{number: unique_int(), kind: :note, body: "FYI"}))
    |> Repo.insert!()
  end

  def message_struct(%Thread{} = thread, author, fields \\ []) do
    struct!(
      %Message{
        thread_id: thread.id,
        session_id: thread.session_id,
        author_agent_id: author && author.id
      },
      fields
    )
  end

  def event_fixture(%Session{} = session, attrs \\ %{}) do
    %Event{session_id: session.id}
    |> Event.changeset(Enum.into(attrs, %{seq: unique_int(), type: :agent_joined}))
    |> Repo.insert!()
  end

  def join_failure_fixture(session, attrs \\ %{}) do
    %JoinFailure{session_id: session && session.id}
    |> JoinFailure.changeset(
      Enum.into(attrs, %{ip: "198.51.100.1", reason: :invalid_secret, attempted_code: "C3-X"})
    )
    |> Repo.insert!()
  end

  def ip_ban_fixture(attrs \\ %{}) do
    %IpBan{}
    |> IpBan.changeset(
      Enum.into(attrs, %{
        ip: "198.51.100.1",
        reason: :invalid_secret,
        banned_until: DateTime.add(DateTime.utc_now(), 3600)
      })
    )
    |> Repo.insert!()
  end

  def idempotency_key_fixture(%Agent{} = agent, attrs \\ %{}) do
    %IdempotencyKey{agent_id: agent.id}
    |> IdempotencyKey.changeset(
      Enum.into(attrs, %{
        key: "key-#{unique_int()}",
        request_hash: "sha",
        response_status: 201,
        response_body: %{"ok" => true}
      })
    )
    |> Repo.insert!()
  end
end
