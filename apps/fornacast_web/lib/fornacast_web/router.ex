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

  pipeline :private_no_store do
    plug :put_private_no_store
  end

  scope "/", FornacastWeb do
    get "/health", HealthController, :show

    get "/:owner/:repo_dot_git/info/refs", GitHTTPController, :info_refs
    post "/:owner/:repo_dot_git/git-upload-pack", GitHTTPController, :upload_pack
    post "/:owner/:repo_dot_git/git-receive-pack", GitHTTPController, :receive_pack
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
  end

  scope "/", FornacastWeb do
    pipe_through [:private_no_store, :browser, :authenticated]

    get "/settings/github", GitHubSettingsController, :index
    post "/settings/github", GitHubSettingsController, :create
    post "/settings/github/:identity_id/reverify", GitHubSettingsController, :reverify
    put "/settings/github/:identity_id/credential", GitHubSettingsController, :replace

    delete "/settings/github/:identity_id/credential",
           GitHubSettingsController,
           :delete_credential

    delete "/settings/github/:identity_id", GitHubSettingsController, :unlink

    get "/repos/import", ImportController, :repository_new
    post "/repos/import/discover", ImportController, :repository_discover
    get "/organizations/import", ImportController, :organization_new
    post "/organizations/import/discover", ImportController, :organization_discover
    get "/imports/:id", ImportController, :show
    get "/imports/:id/conflicts", ImportController, :conflicts
    patch "/imports/:id/conflicts", ImportController, :resolve_conflicts
    get "/imports/:id/review", ImportController, :review
    patch "/imports/:id/destination", ImportController, :destination
    patch "/imports/:id/selection", ImportController, :selection
  end

  scope "/", FornacastWeb do
    pipe_through [:browser, :authenticated]

    get "/", DashboardController, :index
    get "/issues", WorkbenchController, :issues
    get "/pulls", WorkbenchController, :pull_requests
    get "/ssh-keys", SSHKeyController, :index
    post "/ssh-keys", SSHKeyController, :create
    delete "/ssh-keys/:id", SSHKeyController, :delete
    get "/settings", SettingsController, :index
    get "/settings/ssh-keys", SSHKeyController, :index
    post "/settings/ssh-keys", SSHKeyController, :create
    delete "/settings/ssh-keys/:id", SSHKeyController, :delete
    get "/settings/api-keys", APIKeyController, :index
    post "/settings/api-keys", APIKeyController, :create
    delete "/settings/api-keys/:id", APIKeyController, :delete
    get "/organizations/new", OrganizationController, :new
    post "/organizations", OrganizationController, :create

    get "/repos/new", RepositoryController, :new
    post "/repos", RepositoryController, :create

    get "/:owner", OrganizationController, :show
  end

  scope "/", FornacastWeb do
    pipe_through :browser

    get "/:owner/:repo/issues", IssueController, :index
    get "/:owner/:repo/issues/new", IssueController, :new
    post "/:owner/:repo/issues", IssueController, :create
    get "/:owner/:repo/issues/:number/edit", IssueController, :edit
    patch "/:owner/:repo/issues/:number", IssueController, :update
    post "/:owner/:repo/issues/:number/comments", IssueController, :comment
    patch "/:owner/:repo/issues/:number/comments/:id", IssueController, :update_comment
    delete "/:owner/:repo/issues/:number/comments/:id", IssueController, :delete_comment
    patch "/:owner/:repo/issues/:number/state", IssueController, :state
    get "/:owner/:repo/issues/:number", IssueController, :show
    get "/:owner/:repo/pulls", PullRequestController, :index
    get "/:owner/:repo/pulls/new", PullRequestController, :new
    post "/:owner/:repo/pulls", PullRequestController, :create
    get "/:owner/:repo/pulls/:number/commits", PullRequestController, :commits
    get "/:owner/:repo/pulls/:number/files", PullRequestController, :files
    patch "/:owner/:repo/pulls/:number/state", PullRequestController, :state
    post "/:owner/:repo/pulls/:number/merge", PullRequestController, :merge
    get "/:owner/:repo/pulls/:number", PullRequestController, :show
    get "/:owner/:repo", RepositoryController, :show
    get "/:owner/:repo/branches", RepositoryController, :branches
    get "/:owner/:repo/tags", RepositoryController, :tags
    get "/:owner/:repo/commits/:ref", RepositoryController, :commits
    get "/:owner/:repo/commits/*ref", RepositoryController, :commits
    get "/:owner/:repo/commit/:sha", RepositoryController, :commit
    get "/:owner/:repo/search", RepositoryController, :search
    get "/:owner/:repo/src/*segments", RepositoryController, :src
    get "/:owner/:repo/raw/*segments", RepositoryController, :raw
  end

  defp put_private_no_store(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
