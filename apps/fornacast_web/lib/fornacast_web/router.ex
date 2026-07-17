defmodule FornacastWeb.Router do
  use FornacastWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug FornacastWeb.Plugs.RequireSetup
    plug FornacastWeb.Plugs.CurrentUser
  end

  pipeline :setup do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :authenticated do
    plug FornacastWeb.Plugs.RequireUser
  end

  scope "/", FornacastWeb do
    get "/health", HealthController, :show

    get "/:owner/:repo_dot_git/info/refs", GitHTTPController, :info_refs
    post "/:owner/:repo_dot_git/git-upload-pack", GitHTTPController, :upload_pack
  end

  scope "/", FornacastWeb do
    pipe_through :setup

    get "/setup", SetupController, :new
    post "/setup", SetupController, :create
  end

  scope "/", FornacastWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete

    pipe_through :authenticated

    get "/", DashboardController, :index
    get "/issues", WorkbenchController, :issues
    get "/pulls", WorkbenchController, :pull_requests
    get "/ssh-keys", SSHKeyController, :index
    post "/ssh-keys", SSHKeyController, :create
    delete "/ssh-keys/:id", SSHKeyController, :delete
    get "/settings/ssh-keys", SSHKeyController, :index
    post "/settings/ssh-keys", SSHKeyController, :create
    delete "/settings/ssh-keys/:id", SSHKeyController, :delete
    get "/settings/api-keys", APIKeyController, :index
    post "/settings/api-keys", APIKeyController, :create
    delete "/settings/api-keys/:id", APIKeyController, :delete

    get "/organizations/new", OrganizationController, :new
    post "/organizations", OrganizationController, :create

    get "/repos/new", RepositoryController, :new
    get "/repos/import", RepositoryController, :import_new
    post "/repos", RepositoryController, :create

    get "/:owner", OrganizationController, :show
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
