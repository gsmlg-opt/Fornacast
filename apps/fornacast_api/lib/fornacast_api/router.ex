defmodule FornacastAPI.Router do
  use FornacastAPI, :router

  scope "/", FornacastAPI do
    get "/health", HealthController, :show
  end
end
