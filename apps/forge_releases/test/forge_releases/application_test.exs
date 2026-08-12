defmodule ForgeReleases.ApplicationTest do
  use ExUnit.Case, async: true

  test "release and development startup include forge_releases in dependency order" do
    release_apps =
      FornacastUmbrella.MixProject.releases()
      |> Keyword.fetch!(:fornacast)
      |> Keyword.fetch!(:applications)
      |> Keyword.keys()

    assert release_apps == [
             :fornacast,
             :forge_accounts,
             :forge_repos,
             :forge_issues,
             :forge_pulls,
             :forge_releases,
             :git_core,
             :git_transport,
             :fornacast_web,
             :fornacast_api
           ]

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

  test "only the core ex_storage_service application is available" do
    assert Application.spec(:ex_storage_service)
    refute Application.spec(:ex_storage_service_s3)
  end
end
