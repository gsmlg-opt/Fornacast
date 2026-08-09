defmodule FornacastAPI.Router do
  use FornacastAPI, :router

  pipeline :api_context do
    plug FornacastAPI.Plugs.UserAgent
    plug FornacastAPI.Plugs.APIVersion
    plug FornacastAPI.Plugs.MediaType
    plug FornacastAPI.Plugs.Authentication
    plug FornacastAPI.Plugs.RateLimit
  end

  pipeline :graphql do
    plug FornacastAPI.Plugs.UserAgent
    plug FornacastAPI.Plugs.Authentication
    plug FornacastAPI.Plugs.RateLimit
    plug FornacastAPI.GraphQL.Context

    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Jason
  end

  scope "/", FornacastAPI do
    get "/health", HealthController, :show
    get "/.well-known/fornacast", WellKnownController, :fornacast
  end

  scope "/api" do
    pipe_through :graphql

    forward "/graphql", Absinthe.Plug, schema: FornacastAPI.GraphQL.Schema
  end

  scope "/api/v3", FornacastAPI do
    pipe_through :api_context

    get "/versions", MetaController, :versions
    get "/rate_limit", MetaController, :rate_limit
    get "/user/repos", RepositoryController, :for_authenticated_user
    post "/user/repos", RepositoryController, :create_for_authenticated_user
    get "/user/orgs", OrganizationController, :for_authenticated_user
    get "/user", UserController, :authenticated
    get "/users/:username/repos", RepositoryController, :for_user
    get "/users/:username", UserController, :show
    get "/orgs/:org/repos", RepositoryController, :for_organization
    post "/orgs/:org/repos", RepositoryController, :create_for_organization
    get "/orgs/:org", OrganizationController, :show
    patch "/orgs/:org", OrganizationController, :update
    post "/admin/organizations", OrganizationController, :create
    get "/repos/:owner/:repo", RepositoryController, :show
    patch "/repos/:owner/:repo", RepositoryController, :update

    patch "/repos/:owner/:repo/issues/comments/:comment_id", IssueCommentController, :update
    delete "/repos/:owner/:repo/issues/comments/:comment_id", IssueCommentController, :delete
    get "/repos/:owner/:repo/issues", IssueController, :index
    post "/repos/:owner/:repo/issues", IssueController, :create
    get "/repos/:owner/:repo/issues/:issue_number", IssueController, :show
    patch "/repos/:owner/:repo/issues/:issue_number", IssueController, :update

    get "/repos/:owner/:repo/pulls", PullController, :index
    post "/repos/:owner/:repo/pulls", PullController, :create
    get "/repos/:owner/:repo/pulls/:pull_number/merge", PullMergeController, :check
    put "/repos/:owner/:repo/pulls/:pull_number/merge", PullMergeController, :merge
    get "/repos/:owner/:repo/pulls/:pull_number", PullController, :show
    patch "/repos/:owner/:repo/pulls/:pull_number", PullController, :update

    get "/repos/:owner/:repo/issues/:issue_number/comments", IssueCommentController, :index
    post "/repos/:owner/:repo/issues/:issue_number/comments", IssueCommentController, :create
    match :*, "/*path", FallbackController, :not_found
  end

  scope "/api/uploads", FornacastAPI do
    pipe_through :api_context

    match :*, "/*path", FallbackController, :not_found
  end
end
