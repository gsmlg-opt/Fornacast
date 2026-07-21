defmodule FornacastAPI.Router do
  use FornacastAPI, :router

  pipeline :api_context do
    plug FornacastAPI.Plugs.UserAgent
    plug FornacastAPI.Plugs.APIVersion
    plug FornacastAPI.Plugs.MediaType
  end

  scope "/", FornacastAPI do
    get "/health", HealthController, :show
  end

  scope "/api/v3", FornacastAPI do
    pipe_through :api_context

    get "/versions", MetaController, :versions
    match :*, "/*path", FallbackController, :not_found
  end

  scope "/api/uploads", FornacastAPI do
    pipe_through :api_context

    match :*, "/*path", FallbackController, :not_found
  end
end
