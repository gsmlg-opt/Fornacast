defmodule ForgeReleases.ApplicationTest do
  use ExUnit.Case, async: false

  test "release and development startup include forge_releases in dependency order" do
    release_apps =
      FornacastUmbrella.MixProject.releases()
      |> Keyword.fetch!(:fornacast)
      |> Keyword.fetch!(:applications)

    assert release_apps == [
             fornacast: :permanent,
             forge_accounts: :permanent,
             forge_repos: :permanent,
             forge_imports: :permanent,
             forge_issues: :permanent,
             forge_pulls: :permanent,
             ex_storage_service: :temporary,
             forge_releases: :permanent,
             git_core: :permanent,
             git_transport: :permanent,
             fornacast_web: :permanent,
             fornacast_api: :permanent
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

  @tag :tmp_dir
  test "release-mode ESS failure heals without terminating the permanent host", %{
    tmp_dir: tmp_dir
  } do
    project_root = Path.expand("../../../..", __DIR__)
    probe = Path.join(project_root, "apps/forge_releases/test/support/release_mode_recovery.exs")

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-start", "--no-compile", probe],
        cd: project_root,
        env: [
          {"MIX_ENV", "test"},
          {"FORNACAST_RELEASE_RECOVERY_TMP", tmp_dir}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "release-mode-recovery:ok"
  end

  test "only the core ex_storage_service application is available" do
    assert Application.spec(:ex_storage_service)
    refute Application.spec(:ex_storage_service_s3)
  end

  test "forge_releases owns the storage subtree" do
    assert Process.whereis(ForgeReleases.Supervisor)
    assert Process.whereis(ForgeReleases.AssetStorage.Supervisor)
    assert Process.whereis(ForgeReleases.AssetStorage.InstanceSupervisor)
    assert Process.whereis(ForgeReleases.AssetStorage.Manager)
  end
end
