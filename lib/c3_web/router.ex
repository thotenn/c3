defmodule C3Web.Router do
  use C3Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {C3Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :v1 do
    plug :accepts, ["json"]
    plug C3Web.Plugs.RealIp
    plug C3Web.Plugs.RateLimit, :ip
  end

  pipeline :agent do
    plug C3Web.Plugs.AgentAuth
    plug C3Web.Plugs.RateLimit, :token
    plug C3Web.Plugs.Idempotency
  end

  # The watcher's feed: a sign of life of the agent, not activity on the session.
  pipeline :feed do
    plug C3Web.Plugs.AgentAuth, activity: false
    plug C3Web.Plugs.RateLimit, :token
  end

  # SSE clients send `Accept: text/event-stream`, which `:v1` would refuse with a 406.
  pipeline :sse do
    plug C3Web.Plugs.RealIp
    plug C3Web.Plugs.RateLimit, :ip
  end

  # The remote MCP endpoint: tool calls are dispatched in-process as `/v1` requests.
  # No `accepts`: a legacy client's `GET` (`Accept: text/event-stream`) must get `405`, not `406`.
  pipeline :mcp do
    plug C3Web.Plugs.Origin
    plug C3Web.Plugs.RealIp
    plug C3Web.Plugs.RateLimit, :ip
  end

  scope "/", C3Web do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", C3Web do
    pipe_through :api

    get "/healthz", HealthController, :show
  end

  scope "/", C3Web do
    pipe_through :mcp

    post "/mcp", MCPController, :post
    get "/mcp", MCPController, :not_allowed
    delete "/mcp", MCPController, :not_allowed
  end

  scope "/v1", C3Web.V1 do
    pipe_through :v1

    post "/sessions", SessionController, :create
    post "/sessions/:code/join", SessionController, :join

    scope "/" do
      pipe_through :agent

      get "/sessions/:code", SessionController, :show
      post "/sessions/:code/leave", SessionController, :leave
      post "/sessions/:code/close", SessionController, :close
      post "/sessions/:code/unlock", SessionController, :unlock

      get "/sessions/:code/threads", ThreadController, :index
      post "/sessions/:code/threads", ThreadController, :create
      get "/threads/:id", ThreadController, :show
      post "/threads/:id/messages", ThreadController, :post_message
      post "/threads/:id/claim", ThreadController, :claim
      post "/threads/:id/cancel", ThreadController, :cancel
      post "/threads/:id/finish", ThreadController, :finish
      post "/threads/:id/reopen", ThreadController, :reopen

      get "/inbox", InboxController, :show
    end

    scope "/" do
      pipe_through :feed

      get "/sessions/:code/events", EventController, :index
      post "/heartbeat", EventController, :heartbeat
    end
  end

  scope "/v1", C3Web.V1 do
    pipe_through [:sse, :feed]

    get "/sessions/:code/events/stream", EventController, :stream
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:c3, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: C3Web.Telemetry
    end
  end
end
