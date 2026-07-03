defmodule FornacastWeb.Router do
  use FornacastWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug FornacastWeb.Plugs.CurrentUser
  end

  pipeline :authenticated do
    plug FornacastWeb.Plugs.RequireUser
  end

  scope "/", FornacastWeb do
    get "/health", HealthController, :show

    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete

    pipe_through :authenticated

    get "/", DashboardController, :index
    get "/ssh-keys", SSHKeyController, :index
    post "/ssh-keys", SSHKeyController, :create
    delete "/ssh-keys/:id", SSHKeyController, :delete

    get "/repos/new", RepositoryController, :new
    post "/repos", RepositoryController, :create

    get "/:owner/:repo", RepositoryController, :show
    get "/:owner/:repo/branches", RepositoryController, :branches
    get "/:owner/:repo/tags", RepositoryController, :tags
    get "/:owner/:repo/commits/:ref", RepositoryController, :commits
    get "/:owner/:repo/commits/*ref", RepositoryController, :commits
    get "/:owner/:repo/commit/:sha", RepositoryController, :commit
    get "/:owner/:repo/src/*segments", RepositoryController, :src
    get "/:owner/:repo/raw/*segments", RepositoryController, :raw
  end
end
