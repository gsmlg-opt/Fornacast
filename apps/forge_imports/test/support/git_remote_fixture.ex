defmodule ForgeImports.TestSupport.GitRemoteFixture do
  @moduledoc false

  alias ForgeImports.RepositoryItem

  @spec bare_repo!(Path.t(), keyword()) :: Path.t()
  def bare_repo!(tmp_dir, opts \\ []) when is_binary(tmp_dir) and is_list(opts) do
    branch = Keyword.get(opts, :branch, "main")
    work = Path.join(tmp_dir, "work-#{System.unique_integer([:positive])}")
    bare = Path.join(tmp_dir, "source-#{System.unique_integer([:positive])}.git")

    File.mkdir_p!(work)
    git!(["init", "--initial-branch=#{branch}"], work)
    git!(["config", "user.name", "Fornacast Import E2E"], work)
    git!(["config", "user.email", "import-e2e@example.test"], work)

    readme = Keyword.get(opts, :readme, "# Imported repository\n")
    File.write!(Path.join(work, "README.md"), readme)
    git!(["add", "README.md"], work)
    git!(["commit", "-m", Keyword.get(opts, :commit_message, "initial import")], work)

    extra = Keyword.get(opts, :extra_files, [])

    if extra != [] do
      for {relative_path, contents} <- extra do
        absolute = Path.join(work, relative_path)
        File.mkdir_p!(Path.dirname(absolute))
        File.write!(absolute, contents)
      end

      git!(["add", "."], work)
      git!(["commit", "-m", "extra import files"], work)
    end

    git!(["clone", "--bare", work, bare], tmp_dir)
    bare
  end

  @spec head_sha!(Path.t(), String.t()) :: String.t()
  def head_sha!(bare_path, ref \\ "refs/heads/main") when is_binary(bare_path) do
    git!(["--git-dir=#{bare_path}", "rev-parse", ref], bare_path)
  end

  @spec stage_item!(RepositoryItem.t(), pos_integer(), Path.t()) ::
          RepositoryItem.t()
  def stage_item!(%RepositoryItem{} = item, owner_id, source)
      when is_integer(owner_id) and is_binary(source) do
    import Ecto.Query

    alias Ecto.Multi
    alias ForgeImports.{Persistence, RepositoryItem}
    alias ForgeRepos.Repository
    alias Fornacast.Repo

    {:ok, %{shadow: shadow}} =
      Multi.new()
      |> ForgeRepos.create_import_shadow(:shadow, owner_id, %{
        item_id: item.id,
        generation: 1
      })
      |> Repo.transaction()

    staged_path = ForgeRepos.absolute_storage_path(shadow)
    File.mkdir_p!(Path.dirname(staged_path))

    git = System.find_executable("git") || raise "git is required"

    {output, 0} =
      System.cmd(git, ["clone", "--mirror", source, staged_path], stderr_to_stdout: true)

    File.chmod!(staged_path, 0o700)

    now = DateTime.utc_now(:second)

    if 1 !=
         Repo.update_all(
           from(candidate in RepositoryItem, where: candidate.id == ^item.id),
           set: [
             state: :git_staged,
             hidden_repository_id: shadow.id,
             staged_storage_path: staged_path,
             source_git: %{
               "empty" => false,
               "default_branch" => "main",
               "refs" => 1,
               "bytes" => max(byte_size(output), 1),
               "lfs_detected" => false,
               "submodules_detected" => false,
               "scan_truncated" => false
             },
             checkpoint: %{"git_staged" => true, "unsupported_scan" => "complete"},
             updated_at: now
           ]
         )
         |> elem(0) do
      raise "git staging update failed"
    end

    Repo.get!(RepositoryItem, item.id)
  end

  @spec mirror_remote_module() :: module()
  def mirror_remote_module, do: __MODULE__.MirrorRemote

  @spec refute_pat_leaks!(String.t(), String.t()) :: :ok
  def refute_pat_leaks!(haystack, pat) when is_binary(haystack) and is_binary(pat) do
    if haystack =~ pat, do: raise("expected PAT to stay out of persisted output")
    if haystack =~ "authorization", do: raise("expected authorization header to stay redacted")
    if haystack =~ "Bearer ", do: raise("expected bearer token to stay redacted")
    :ok
  end

  @spec refute_pat_in_tree!(Path.t(), String.t()) :: :ok
  def refute_pat_in_tree!(root, pat) when is_binary(root) and is_binary(pat) do
    for path <- list_files(root), File.regular?(path) do
      contents = File.read!(path)
      refute_pat_leaks!(contents, pat)
    end

    :ok
  end

  defp list_files(root) do
    case File.ls(root) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(root, name)

          cond do
            File.dir?(path) -> list_files(path)
            true -> [path]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp git!(args, directory \\ File.cwd!()) do
    git = System.find_executable("git") || raise "git is required"
    {output, status} = System.cmd(git, args, cd: directory, stderr_to_stdout: true)
    if status != 0, do: raise("git failed: #{output}")
    String.trim(output)
  end

  defmodule MirrorRemote do
    @moduledoc false

    @spec mirror(map(), String.t(), keyword()) ::
            {:ok, GitCore.Remote.Result.t()} | {:error, GitCore.Remote.Error.t()}
    def mirror(request, pat, opts) do
      if Keyword.get(opts, :fail?, false) do
        {:error, %GitCore.Remote.Error{kind: :source_validation, detail: :injected_failure}}
      else
        do_mirror(request, pat, opts)
      end
    end

    defp do_mirror(request, pat, opts) do
      expected_pat = Keyword.fetch!(opts, :expected_pat)
      source = Keyword.fetch!(opts, :source)

      if pat != expected_pat, do: raise("unexpected credential in mirror remote")

      git = System.find_executable("git") || raise "git is required"
      {output, status} = System.cmd(git, ["clone", "--mirror", source, request.destination])

      if status != 0 do
        {:error, %GitCore.Remote.Error{kind: :source_validation, detail: String.trim(output)}}
      else
        File.chmod!(request.destination, 0o700)

        {:ok,
         %GitCore.Remote.Result{
           path: request.destination,
           empty?: false,
           default_branch: request.default_branch,
           refs: 1,
           bytes: byte_size(output)
         }}
      end
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")

    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end
end
