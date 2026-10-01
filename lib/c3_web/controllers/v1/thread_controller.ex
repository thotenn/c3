defmodule C3Web.V1.ThreadController do
  @moduledoc """
  Threads and messages (spec, *API › Hilos y mensajes*). Threads are addressed by their
  readable id inside the agent's session (`T3`); the token already says which session.
  """
  use C3Web, :controller

  alias C3.Threads

  action_fallback C3Web.V1.FallbackController

  @statuses ~w(pending processing answered finished)

  def index(conn, params) do
    %{current_session: session, current_agent: agent} = conn.assigns

    with {:ok, opts} <- list_opts(params, agent) do
      threads = Threads.list_threads(session, [preload: :opened_by_agent] ++ opts)
      render(conn, :index, threads: threads, states: Threads.states(threads))
    end
  end

  def create(conn, params) do
    with {:ok, thread} <- Threads.open_thread(conn.assigns.current_agent, params) do
      conn |> put_status(:created) |> render_thread(thread, Threads.list_messages(thread))
    end
  end

  def show(conn, %{"id" => id} = params) do
    with {:ok, thread} <- Threads.fetch_thread(conn.assigns.current_agent, id),
         {:ok, since} <- since(thread, params["since"]) do
      render_thread(conn, thread, Threads.list_messages(thread, since: since))
    end
  end

  def post_message(conn, %{"id" => id} = params) do
    agent = conn.assigns.current_agent

    with {:ok, thread} <- Threads.fetch_thread(agent, id),
         {:ok, posted} <- Threads.post_message(agent, thread, params) do
      conn
      |> put_status(:created)
      |> render(:posted,
        thread: summary(posted.thread),
        messages: Threads.preload_messages(posted.messages),
        resolved: posted.resolved
      )
    end
  end

  def claim(conn, %{"id" => id} = params) do
    agent = conn.assigns.current_agent

    with {:ok, thread} <- Threads.fetch_thread(agent, id),
         {:ok, %{thread: thread, claimed: claimed}} <- Threads.claim(agent, thread, params) do
      render(conn, :action, thread: summary(thread), extra: %{claimed: claimed})
    end
  end

  def cancel(conn, %{"id" => id} = params) do
    agent = conn.assigns.current_agent

    with {:ok, thread} <- Threads.fetch_thread(agent, id),
         {:ok, result} <- Threads.cancel(agent, thread, params) do
      render(conn, :action,
        thread: summary(result.thread),
        extra: %{cancelled: result.cancelled, note: result.note}
      )
    end
  end

  def finish(conn, %{"id" => id} = params) do
    agent = conn.assigns.current_agent

    with {:ok, thread} <- Threads.fetch_thread(agent, id),
         {:ok, result} <- Threads.finish(agent, thread, params) do
      render(conn, :action,
        thread: summary(result.thread),
        extra: %{finished: result.changed, cancelled: result.cancelled}
      )
    end
  end

  def reopen(conn, %{"id" => id}) do
    agent = conn.assigns.current_agent

    with {:ok, thread} <- Threads.fetch_thread(agent, id),
         {:ok, result} <- Threads.reopen(agent, thread) do
      render(conn, :action, thread: summary(result.thread), extra: %{reopened: result.changed})
    end
  end

  defp render_thread(conn, thread, messages) do
    {thread, state} = summary(thread)
    render(conn, :show, thread: thread, state: state, messages: messages)
  end

  defp summary(thread) do
    thread = Threads.preload_threads(thread)
    {thread, Threads.state(thread)}
  end

  defp list_opts(params, agent) do
    with {:ok, status} <- status_opt(params["status"]),
         {:ok, awaiting} <- awaiting_opt(params["awaiting"], agent) do
      {:ok, [status: status, awaiting: awaiting]}
    end
  end

  defp status_opt(nil), do: {:ok, nil}
  defp status_opt(status) when status in @statuses, do: {:ok, String.to_existing_atom(status)}

  defp status_opt(status) do
    {:error,
     {:invalid, "status must be one of #{Enum.join(@statuses, ", ")}",
      %{status: [inspect(status)]}}}
  end

  defp awaiting_opt(nil, _agent), do: {:ok, nil}
  defp awaiting_opt("me", agent), do: {:ok, agent}

  defp awaiting_opt(other, _agent) do
    {:error, {:invalid, "awaiting only takes me", %{awaiting: [inspect(other)]}}}
  end

  defp since(_thread, nil), do: {:ok, nil}
  defp since(thread, ref), do: Threads.parse_message_ref(thread, ref)
end
