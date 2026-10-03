defmodule C3Web.V1.SearchJSON do
  @moduledoc """
  JSON for search results: where each message is (`T3.4` in `T3`, with the thread's title), who
  wrote it, and a snippet of its body around the first term found — not the whole body, which
  `GET /v1/threads/{id}` has.
  """
  alias C3.{Search, Threads}

  def index(%{messages: messages, terms: terms}) do
    %{
      results:
        Enum.map(messages, fn m ->
          %{
            message: Threads.message_ref(m.thread, m),
            thread: Threads.thread_ref(m.thread),
            title: m.thread.title,
            kind: m.kind,
            author: m.author_agent.name,
            snippet: Search.snippet(m.body, terms),
            created_at: m.inserted_at
          }
        end)
    }
  end
end
