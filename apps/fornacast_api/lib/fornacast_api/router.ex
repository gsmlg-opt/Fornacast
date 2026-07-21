defmodule FornacastAPI.Router do
  use FornacastAPI, :router

  pipeline :api_context do
    plug FornacastAPI.Plugs.UserAgent
    plug FornacastAPI.Plugs.APIVersion
    plug FornacastAPI.Plugs.MediaType
    plug FornacastAPI.Plugs.Authentication
    plug FornacastAPI.Plugs.RateLimit
  end

  scope "/", FornacastAPI do
    get "/health", HealthController, :show
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
    match :*, "/*path", FallbackController, :not_found
  end

  scope "/api/uploads", FornacastAPI do
    pipe_through :api_context

    match :*, "/*path", FallbackController, :not_found
  end
end
