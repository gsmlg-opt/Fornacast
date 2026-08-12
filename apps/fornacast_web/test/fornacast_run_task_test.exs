defmodule Mix.Tasks.Fornacast.RunTest do
  use ExUnit.Case, async: true

  test "service applications include the issue, pull, and release applications before the API and web endpoints" do
    assert Mix.Tasks.Fornacast.Run.service_applications() == [
             :fornacast,
             :forge_accounts,
             :forge_repos,
             :git_core,
             :git_transport,
             :forge_issues,
             :forge_pulls,
             :forge_releases,
             :fornacast_api,
             :fornacast_web
           ]
  end

  test "root release starts the issue, pull, and release applications permanently" do
    applications = FornacastUmbrella.MixProject.releases()[:fornacast][:applications]

    assert applications[:forge_issues] == :permanent
    assert applications[:forge_pulls] == :permanent
    assert applications[:forge_releases] == :permanent
  end

  test "service_dependency_applications leaves the web endpoint to phx.server" do
    assert Mix.Tasks.Fornacast.Run.service_dependency_applications() == [
             :fornacast,
             :forge_accounts,
             :forge_repos,
             :git_core,
             :git_transport,
             :forge_issues,
             :forge_pulls,
             :forge_releases,
             :fornacast_api
           ]
  end
end
