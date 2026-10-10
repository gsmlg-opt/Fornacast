defmodule FornacastWeb.BuildInfo do
  @moduledoc "Build metadata embedded in the application, without runtime Git access."

  @root Path.expand("../../../..", __DIR__)

  git = fn args ->
    try do
      case System.cmd("git", args, cd: @root, stderr_to_stdout: true) do
        {output, 0} -> String.trim(output)
        _ -> nil
      end
    rescue
      ErlangError -> nil
    end
  end

  override = fn name ->
    case System.get_env(name) do
      nil -> nil
      value -> if String.trim(value) != "", do: String.trim(value)
    end
  end

  branch_ref = git.(["symbolic-ref", "--quiet", "HEAD"])

  for ref <- Enum.reject(["HEAD", "packed-refs", branch_ref], &is_nil/1),
      path = git.(["rev-parse", "--git-path", ref]),
      not is_nil(path) do
    @external_resource Path.expand(path, @root)
  end

  @environment Mix.env()
  @git_ref override.("FORNACAST_BUILD_GIT_REF") ||
             git.(["symbolic-ref", "--quiet", "--short", "HEAD"])
  @git_commit override.("FORNACAST_BUILD_GIT_COMMIT") || git.(["rev-parse", "HEAD"])
  @built_at override.("FORNACAST_BUILD_TIME") || DateTime.to_iso8601(DateTime.utc_now())
  @released_at override.("FORNACAST_RELEASE_TIME")

  @doc "Returns the running application version and the metadata captured at build time."
  def current do
    %{
      version: to_string(Application.spec(:fornacast_web, :vsn)),
      environment: @environment,
      git_ref: @git_ref,
      git_commit: @git_commit,
      built_at: @built_at,
      released_at: @released_at
    }
  end
end
