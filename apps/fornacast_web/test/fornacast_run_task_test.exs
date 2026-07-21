defmodule Mix.Tasks.Fornacast.RunTest do
  use ExUnit.Case, async: true

  test "service_applications starts the API immediately before the web endpoint" do
    assert Mix.Tasks.Fornacast.Run.service_applications() == [
             :fornacast,
             :forge_accounts,
             :forge_repos,
             :git_core,
             :git_transport,
             :fornacast_api,
             :fornacast_web
           ]
  end

  test "service_dependency_applications leaves the web endpoint to phx.server" do
    assert Mix.Tasks.Fornacast.Run.service_dependency_applications() == [
             :fornacast,
             :forge_accounts,
             :forge_repos,
             :git_core,
             :git_transport,
             :fornacast_api
           ]
  end
end
