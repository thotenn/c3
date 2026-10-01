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

  scope "/", C3Web do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", C3Web do
    pipe_through :api

    get "/healthz", HealthController, :show
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
