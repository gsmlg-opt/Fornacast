defmodule ForgeRepos.RepositoryReadCallsiteAuditTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @repository_storage_reads MapSet.new(~w(
    branches commit commit_history commit_page commit_range_page commit_summary
    contained_tree_identity diff_between diff_commit empty? exact_ref is_bare_repository?
    list_refs merge_analysis pack_objects read_blob read_blob_complete read_tree
    read_tree_with_history ref_page ref_summary ref_summary_for_route release_blob
    repository_analysis repository_disk_usage resolve_snapshot search_tree tags
  )a)
  @git_core_classification %{
    {"apps/forge_pulls/lib/forge_pulls.ex", :branch_option_pages, :ref_page} => :read_handle,
    {"apps/forge_pulls/lib/forge_pulls.ex", :list_commits, :commit_range_page} => :read_handle,
    {"apps/forge_pulls/lib/forge_pulls.ex", :changed_files, :diff_between} => :read_handle,
    {"apps/forge_pulls/lib/forge_pulls.ex", :resolve_ref_path, :resolve_snapshot} => :read_handle,
    {"apps/forge_pulls/lib/forge_pulls.ex", :pull_analysis_path, :merge_analysis} => :read_handle,
    {"apps/forge_pulls/lib/forge_pulls.ex", :exact_ref, :exact_ref} => :writer_fence,
    {"apps/forge_pulls/lib/forge_pulls.ex", :merge_analysis, :merge_analysis} => :writer_fence,
    {"apps/forge_pulls/lib/forge_pulls/merge_recovery.ex", :read_base_ref, :exact_ref} =>
      :writer_fence,
    {"apps/forge_repos/lib/forge_repos.ex", :build_repository_view_with_handle,
     :repository_disk_usage} => :read_handle,
    {"apps/forge_repos/lib/forge_repos.ex", :empty?, :empty?} => :read_handle,
    {"apps/forge_repos/lib/forge_repos.ex", :validate_changed_default_branch, :resolve_snapshot} =>
      :read_handle,
    {"apps/forge_repos/lib/forge_repos/git_write_recovery.ex", :read_current_ref, :exact_ref} =>
      :writer_fence,
    {"apps/forge_imports/lib/forge_imports/repository_stager.ex", :scan_attribute_paths,
     :read_blob} => :import_lease,
    {"apps/forge_imports/lib/forge_imports/repository_stager.ex", :scan_attribute_paths,
     :release_blob} => :import_lease,
    {"apps/forge_imports/lib/forge_imports/repository_stager.ex", :scan_unsupported, :exact_ref} =>
      :import_lease,
    {"apps/forge_imports/lib/forge_imports/repository_stager.ex", :search, :search_tree} =>
      :import_lease,
    {"apps/forge_imports/lib/forge_imports/repository_worker.ex", :choose_staging_action,
     :is_bare_repository?} => :import_lease,
    {"apps/git_transport/lib/git_transport/receive_pack.ex", :advertise_refs, :list_refs} =>
      :writer_fence,
    {"apps/git_transport/lib/git_transport/receive_pack_worker.ex", :validate_expected_refs,
     :exact_ref} => :writer_fence,
    {"apps/git_transport/lib/git_transport/upload_pack.ex", :advertise_refs_handle, :list_refs} =>
      :read_handle,
    {"apps/git_transport/lib/git_transport/upload_pack.ex", :pack_objects, :pack_objects} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :collaboration, :ref_summary} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :code, :ref_summary} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :build_code, :resolve_snapshot} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :build_code, :commit_summary} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :build_code,
     :read_tree_with_history} => :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :build_code, :repository_analysis} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :build_code,
     :repository_disk_usage} => :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :tree, :read_tree_with_history} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :commit, :commit} => :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :commit, :diff_commit} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :commits, :commit_page} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :refs, :ref_page} => :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :search, :search_tree} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :raw, :read_blob_complete} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :read_blob_result, :read_blob} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :read_readme, :read_blob} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :release_leases, :release_blob} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :empty_result,
     :repository_disk_usage} => :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :load_context, :ref_summary} =>
      :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :load_context,
     :ref_summary_for_route} => :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :finish_context,
     :resolve_snapshot} => :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :optional_chrome_snapshot,
     :resolve_snapshot} => :read_handle,
    {"apps/fornacast_web/lib/fornacast_web/repository_page.ex", :with_optional_chrome_context,
     :ref_summary} => :read_handle,
    {"apps/git_core/lib/git_core/remote.ex", :validate_repository, :is_bare_repository?} =>
      :import_lease,
    {"apps/git_core/lib/git_core/remote.ex", :validate_repository, :empty?} => :import_lease,
    {"apps/git_core/lib/git_core/remote.ex", :validate_default_branch, :exact_ref} =>
      :import_lease,
    {"apps/git_core/lib/git_core/remote.ex", :anchored_cleanup_identity, :contained_tree_identity} =>
      :import_lease
  }

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

  test "opaque handle module has no helpers and only ForgeRepos mentions its struct" do
    handle_source =
      File.read!(Path.join(@root, "apps/forge_repos/lib/forge_repos/repository_read_handle.ex"))

    refute handle_source =~ ~r/\bdef\s+(new|repository|path|close)\b/

    offenders =
      @root
      |> Path.join("apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "/forge_repos.ex"))
      |> Enum.reject(&String.ends_with?(&1, "/repository_read_handle.ex"))
      |> Enum.filter(fn path ->
        source = File.read!(path)

        source =~ ~r/%(?:ForgeRepos\.)?RepositoryReadHandle\{/ or
          source =~ ~r/(?:Map\.(?:get|fetch)|get_in)\([^\n]*repository_read_handle/ or
          source =~ ~r/repository_read_handle\.(?:repository|path|lease)\b/
      end)
      |> Enum.map(&Path.relative_to(&1, @root))

    assert offenders == []
  end

  test "every production GitCore call has an explicit lease classification" do
    calls =
      for path <- Path.wildcard(Path.join(@root, "apps/*/lib/**/*.ex")),
          call <- git_core_calls(path) do
        call
      end
      |> MapSet.new()

    assert calls == MapSet.new(Map.keys(@git_core_classification)),
           "classification mismatch: #{inspect(MapSet.difference(calls, MapSet.new(Map.keys(@git_core_classification))) |> MapSet.to_list())}"

    assert Enum.all?(@git_core_classification, fn {_call, classification} ->
             classification in [:read_handle, :writer_fence, :import_lease]
           end)
  end

  test "global detector catches an unclassified future app call" do
    source = """
    defmodule FutureForge.Reader do
      def refs(path), do: GitCore.list_refs(path)
    end
    """

    assert [{"apps/future_forge/lib/reader.ex", :refs, :list_refs} = call] =
             git_core_calls_from_source(source, "apps/future_forge/lib/reader.ex")

    refute Map.has_key?(@git_core_classification, call)
  end

  defp git_core_calls(path) do
    relative = Path.relative_to(path, @root)
    git_core_calls_from_source(File.read!(path), relative)
  end

  defp git_core_calls_from_source(source, relative) do
    {:ok, ast} = Code.string_to_quoted(source, file: relative)

    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, body]} = node, calls when kind in [:def, :defp] ->
          case definition_name(head) do
            name when is_atom(name) and not is_nil(name) ->
              {node, collect_function_calls(body, relative, name, calls)}

            nil ->
              {node, calls}
          end

        node, calls ->
          {node, calls}
      end)

    calls
  end

  defp definition_name({:when, _, [head | _guards]}), do: definition_name(head)

  defp definition_name({name, _, args})
       when is_atom(name) and (is_list(args) or is_nil(args)),
       do: name

  defp definition_name(_head), do: nil

  defp collect_function_calls(ast, relative, function, calls) do
    {_ast, calls} =
      Macro.prewalk(ast, calls, fn
        {{:., _, [receiver, call]}, _, _args} = node, calls when is_atom(call) ->
          if git_core_receiver?(receiver) and MapSet.member?(@repository_storage_reads, call) do
            {node, [{relative, function, call} | calls]}
          else
            {node, calls}
          end

        node, calls ->
          {node, calls}
      end)

    calls
  end

  defp git_core_receiver?({:__aliases__, _, [:GitCore]}), do: true
  defp git_core_receiver?({:git_core, _, _}), do: true
  defp git_core_receiver?({{:., _, [_context, :git_core]}, _, []}), do: true
  defp git_core_receiver?(_receiver), do: false
end
