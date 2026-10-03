defmodule C3Web.V1.KnowledgeJSON do
  @moduledoc """
  JSON for knowledge entries, compact so a whole recall fits in an agent's context. Only
  readable ids leave: entries `K3`, agents `AG2`, sources `T3` / `T3.4`.
  """
  alias C3.Knowledge
  alias C3.Knowledge.Entry

  def index(%{entries: entries}), do: %{entries: Enum.map(entries, &entry/1)}

  def show(%{entry: entry}), do: entry(entry)

  @doc "One entry."
  def entry(%Entry{} = k) do
    %{
      id: Knowledge.entry_ref(k),
      topic: k.topic,
      kind: k.kind,
      summary: k.summary,
      status: k.status,
      author: k.author_agent.name,
      source: k.source,
      supersedes: k.supersedes && Knowledge.entry_ref(k.supersedes),
      created_at: k.inserted_at
    }
  end
end
