defmodule ForgeRepos.RepositoryReadCallsiteAuditTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  test "ready-repository consumers do not resolve storage before a read or write permit" do
    for relative <- [
          "apps/forge_pulls/lib/forge_pulls.ex",
          "apps/fornacast_web/lib/fornacast_web/repository_page.ex",
          "apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex",
          "apps/git_transport/lib/git_transport/upload_pack.ex",
          "apps/git_transport/lib/git_transport/receive_pack.ex",
          "apps/git_transport/lib/git_transport/exec.ex",
          "apps/git_transport/lib/git_transport/channel.ex"
        ] do
      source = File.read!(Path.join(@root, relative))

      refute source =~ "ForgeRepos.absolute_storage_path",
             "#{relative} resolves repository storage outside the opaque read handle"
    end
  end

  test "remaining qualified storage resolution is limited to importing shadows or writer fences" do
    offenders =
      @root
      |> Path.join("apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        if File.read!(path) =~ "ForgeRepos.absolute_storage_path" do
          [Path.relative_to(path, @root)]
        else
          []
        end
      end)
      |> Enum.reject(fn relative ->
        String.starts_with?(relative, "apps/forge_imports/lib/") or
          relative == "apps/forge_repos/lib/forge_repos/git_write_recovery.ex"
      end)

    assert offenders == []
  end

  test "external consumers use accessors rather than handle fields" do
    offenders =
      @root
      |> Path.join("apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "/repository_read_handle.ex"))
      |> Enum.filter(&(File.read!(&1) =~ ~r/repository_read_handle\.(lease|path|repository)\b/))
      |> Enum.map(&Path.relative_to(&1, @root))

    assert offenders == []
  end
end
