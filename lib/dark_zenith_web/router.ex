defmodule DarkZenithWeb.Router do
  use DarkZenithWeb, :router

  import DarkZenithWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DarkZenithWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_cookie_authenticated_requests
    plug DarkZenithWeb.Api.AuthPlug
  end

  # CSRF protection applies to cookie-authenticated mutating API requests.
  # When an Authorization header is present it is the authoritative credential
  # and the cookie is ignored; with no session cookie at all there is no
  # ambient credential to protect (e.g. curl calling the login endpoint).
  defp protect_cookie_authenticated_requests(conn, _opts) do
    cond do
      get_req_header(conn, "authorization") != [] ->
        conn

      is_nil(get_session(conn, :user_token)) ->
        conn

      true ->
        Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init([]))
    end
  end

  # Repository-serving endpoints consumed by RPM clients: no CSRF or layout,
  # session fetched only for optional browser-cookie authentication.
  pipeline :repo_serving do
    plug :fetch_session
    plug DarkZenithWeb.Plugs.RepoServingAuth
  end

  scope "/", DarkZenithWeb do
    pipe_through :browser

    get "/", PageController, :home

    live_session :repositories_authenticated,
      on_mount: [{DarkZenithWeb.UserAuth, :require_authenticated}] do
      # /repos/new precedes /repos/:slug; the slug "new" is reserved.
      live "/repos/new", RepositoryLive.New, :new
      live "/repos/:slug/settings", RepositoryLive.Settings, :edit
      live "/repos/:slug/upload", RepositoryLive.Upload, :new
    end

    live_session :repositories_public,
      on_mount: [{DarkZenithWeb.UserAuth, :mount_current_scope}] do
      live "/repos", RepositoryLive.Index, :index
      live "/repos/:slug", RepositoryLive.Show, :show
      live "/repos/:slug/packages/:name", PackageLive.Show, :show
      live "/repos/:slug/package-versions/:id", PackageLive.Version, :show
    end
  end

  scope "/repos/:slug", DarkZenithWeb do
    pipe_through :repo_serving

    get "/repodata/:filename", RepoServingController, :repodata
    get "/RPM-GPG-KEY", RepoServingController, :gpg_key
    get "/dark-zenith.repo", RepoServingController, :repo_file
    get "/packages/:id/:filename", RepoServingController, :download
  end

  scope "/api/v1", DarkZenithWeb.Api.V1 do
    pipe_through :api

    post "/auth/login", AuthController, :login
    delete "/auth/logout", AuthController, :logout

    get "/repos", RepoController, :index
    post "/repos", RepoController, :create
    get "/repos/:slug", RepoController, :show
    patch "/repos/:slug", RepoController, :update
    delete "/repos/:slug", RepoController, :delete

    get "/repos/:slug/packages", PackageController, :index
    get "/repos/:slug/packages/:id", PackageController, :show
    get "/repos/:slug/packages/:id/:collection", PackageController, :subresource
    delete "/repos/:slug/packages/:id", PackageController, :delete

    post "/repos/:slug/package-uploads", PackageUploadController, :create
    get "/repos/:slug/package-uploads/:id", PackageUploadController, :show
    post "/repos/:slug/package-uploads/:id/refresh", PackageUploadController, :refresh
    post "/repos/:slug/package-uploads/:id/complete", PackageUploadController, :complete
    delete "/repos/:slug/package-uploads/:id", PackageUploadController, :delete

    get "/repos/:slug/collaborators", CollaboratorController, :index
    post "/repos/:slug/collaborators", CollaboratorController, :create
    # The invitations route precedes the :id route so "invitations" never
    # matches as a collaborator id.
    delete "/repos/:slug/collaborators/invitations/:id",
           CollaboratorController,
           :delete_invitation

    delete "/repos/:slug/collaborators/:id", CollaboratorController, :delete

    get "/api_keys", ApiKeyController, :index
    post "/api_keys", ApiKeyController, :create
    delete "/api_keys/:id", ApiKeyController, :delete
  end

  # Other scopes may use custom stacks.
  # scope "/api", DarkZenithWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:dark_zenith, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DarkZenithWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", DarkZenithWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{DarkZenithWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", DarkZenithWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{DarkZenithWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/confirm", UserLive.ConfirmationInstructions, :new
      live "/users/confirm/:token", UserLive.Confirmation, :edit
      live "/users/reset-password", UserLive.ForgotPassword, :new
      live "/users/reset-password/:token", UserLive.ResetPassword, :edit
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
