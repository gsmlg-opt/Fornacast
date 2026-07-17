defmodule FornacastWeb.RepositoryPage.Result do
  @enforce_keys [:kind, :chrome, :content]
  defstruct [:kind, :chrome, :content, leases: []]
end

defmodule FornacastWeb.RepositoryPage.Chrome do
  @enforce_keys [:owner, :repository, :viewer, :ref_summary, :clone]
  defstruct [:owner, :repository, :viewer, :ref_summary, :snapshot, :clone]
end

defmodule FornacastWeb.RepositoryPage.Clone do
  @enforce_keys [:https_url]
  defstruct [:https_url, :ssh_url, push_commands: []]
end

defmodule FornacastWeb.RepositoryPage.Code do
  @enforce_keys [:commit_summary, :tree]
  defstruct [:commit_summary, :tree, :readme, :analysis, :disk_usage]
end

defmodule FornacastWeb.RepositoryPage.Tree do
  @enforce_keys [:path, :tree]
  defstruct [:path, :tree]
end

defmodule FornacastWeb.RepositoryPage.Blob do
  @enforce_keys [:path, :blob]
  defstruct [:path, :blob]
end

defmodule FornacastWeb.RepositoryPage.Refs do
  @enforce_keys [:kind, :page]
  defstruct [:kind, :page]
end

defmodule FornacastWeb.RepositoryPage.Commits do
  @enforce_keys [:page]
  defstruct [:page]
end

defmodule FornacastWeb.RepositoryPage.Commit do
  @enforce_keys [:commit, :diff]
  defstruct [:commit, :diff, :ref_context]
end

defmodule FornacastWeb.RepositoryPage.Search do
  @enforce_keys [:query, :scope]
  defstruct [:query, :scope, :results, :validation_error]
end

defmodule FornacastWeb.RepositoryPage.Empty do
  @enforce_keys [:write_access]
  defstruct [:write_access, :disk_usage]
end

defmodule FornacastWeb.RepositoryPage.MissingDefault do
  @enforce_keys [:configured_ref]
  defstruct [:configured_ref]
end

defmodule FornacastWeb.RepositoryPage.Raw do
  @enforce_keys [:blob]
  defstruct [:blob]
end

defmodule FornacastWeb.RepositoryPage do
  @moduledoc """
  Composes authorized repository reads into plain, typed page data.

  Callers must authorize the repository before entering this boundary. Blob
  leases returned in a result stay held until the caller invokes `release/1`.
  """

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.{RepositoryMarkdown, RepositoryPage}

  @inline_blob_limit 1_048_576
  @complete_blob_limit 100_000_000

  def code(
        %Repository{} = repository,
        owner,
        viewer,
        selector,
        opts \\ []
      )
      when (is_nil(selector) or is_struct(selector, GitCore.RefSelector)) and is_list(opts) do
    git_core = Keyword.get(opts, :git_core, GitCore)
    path = ForgeRepos.absolute_storage_path(repository)

    with {:ok, ref_summary} <-
           git_core.ref_summary(path,
             selected_ref: selector_full_name(repository, selector)
           ) do
      cond do
        empty?(ref_summary) ->
          {:ok, empty_result(repository, owner, viewer, ref_summary, path, git_core)}

        missing_configured_default?(repository, selector, ref_summary) ->
          {:ok, missing_default_result(repository, owner, viewer, ref_summary)}

        true ->
          build_code(
            repository,
            owner,
            viewer,
            ref_summary,
            path,
            selector || default_selector(repository),
            git_core
          )
      end
    end
  end

  def tree(%Repository{} = repository, owner, viewer, route, page, opts \\ [])
      when is_integer(page) and page > 0 and is_list(opts) do
    with_context(repository, owner, viewer, route, opts, fn context ->
      case context.git_core.read_tree_with_history(
             context.path,
             context.snapshot.oid,
             context.repository_path,
             page,
             []
           ) do
        {:ok, tree} ->
          result(:tree, context.chrome, %RepositoryPage.Tree{
            path: context.repository_path,
            tree: tree
          })

        {:error, %GitCore.Error{kind: :path_not_found}} ->
          read_blob_result(context)

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  def blob(%Repository{} = repository, owner, viewer, route, opts \\ []) when is_list(opts) do
    with_context(repository, owner, viewer, route, opts, fn context ->
      read_blob_result(context)
    end)
  end

  def refs(%Repository{} = repository, owner, viewer, kind, page, opts \\ [])
      when kind in [:branch, :tag] and is_integer(page) and page > 0 and is_list(opts) do
    with_optional_chrome_context(repository, owner, viewer, nil, false, opts, fn context ->
      case context.git_core.ref_page(context.path, kind, page, per_page: 100) do
        {:ok, ref_page} ->
          result(:refs, context.chrome, %RepositoryPage.Refs{kind: kind, page: ref_page})

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  def commits(%Repository{} = repository, owner, viewer, route, page, opts \\ [])
      when is_integer(page) and page > 0 and is_list(opts) do
    with_context(repository, owner, viewer, route, opts, fn context ->
      case context.git_core.commit_page(context.path, context.snapshot.oid, page, per_page: 50) do
        {:ok, commit_page} ->
          result(:commits, context.chrome, %RepositoryPage.Commits{page: commit_page})

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  def commit(%Repository{} = repository, owner, viewer, sha, ref_context, opts \\ [])
      when is_binary(sha) and is_list(opts) do
    with_optional_chrome_context(
      repository,
      owner,
      viewer,
      ref_context,
      true,
      opts,
      fn context ->
        with {:ok, commit} <- context.git_core.commit(context.path, sha),
             {:ok, diff} <- context.git_core.diff_commit(context.path, commit.oid, []) do
          result(:commit, context.chrome, %RepositoryPage.Commit{
            commit: commit,
            diff: diff,
            ref_context: context.snapshot
          })
        end
      end
    )
  end

  def search(%Repository{} = repository, owner, viewer, selector, query, scope, opts \\ [])
      when (is_nil(selector) or is_struct(selector, GitCore.RefSelector)) and
             (is_nil(query) or is_binary(query)) and scope in [:path, :content] and is_list(opts) do
    with_context(repository, owner, viewer, selector, opts, fn context ->
      validation_error = Keyword.get(opts, :validation_error)

      search_result =
        cond do
          validation_error ->
            nil

          is_nil(query) ->
            nil

          true ->
            context.git_core.search_tree(context.path, context.snapshot.oid, query, scope: scope)
        end

      case search_result do
        {:error, error} ->
          {:error, error}

        value ->
          results = if match?({:ok, _}, value), do: elem(value, 1), else: nil

          result(:search, context.chrome, %RepositoryPage.Search{
            query: query || "",
            scope: scope,
            results: results,
            validation_error: validation_error
          })
      end
    end)
  end

  def raw(%Repository{} = repository, owner, viewer, route, opts \\ []) when is_list(opts) do
    with_context(repository, owner, viewer, route, opts, fn context ->
      case context.git_core.read_blob_complete(
             context.path,
             context.snapshot.oid,
             context.repository_path,
             limit: @complete_blob_limit
           ) do
        {:ok, blob} ->
          {:ok,
           %RepositoryPage.Result{
             kind: :raw,
             chrome: context.chrome,
             content: %RepositoryPage.Raw{blob: blob},
             leases: [{context.git_core, blob}]
           }}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  def release(%RepositoryPage.Result{leases: leases}) do
    release_leases(leases)
  end

  defp build_code(repository, owner, viewer, ref_summary, path, selector, git_core) do
    with {:ok, snapshot} <- git_core.resolve_snapshot(path, selector),
         {:ok, commit_summary} <- git_core.commit_summary(path, snapshot.oid, []) do
      {readme, leases} =
        read_readme(git_core, path, snapshot, owner, repository)

      try do
        case git_core.read_tree_with_history(path, snapshot.oid, "", 1, []) do
          {:ok, tree} ->
            chrome = chrome(repository, owner, viewer, ref_summary, snapshot)

            {:ok,
             %RepositoryPage.Result{
               kind: :code,
               chrome: chrome,
               content: %RepositoryPage.Code{
                 commit_summary: commit_summary,
                 tree: tree,
                 readme: readme,
                 analysis: optional(git_core.repository_analysis(path, snapshot.oid, [])),
                 disk_usage: optional(git_core.repository_disk_usage(path, []))
               },
               leases: leases
             }}

          {:error, error} ->
            release_leases(leases)
            {:error, error}
        end
      catch
        kind, reason ->
          release_leases(leases)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp read_readme(git_core, path, snapshot, owner, repository) do
    RepositoryMarkdown.candidates("")
    |> Enum.reduce_while({nil, []}, fn readme_path, _acc ->
      case git_core.read_blob(path, snapshot.oid, readme_path, limit: @inline_blob_limit) do
        {:ok, blob} ->
          {:halt,
           render_readme_blob(git_core, blob, readme_path, snapshot.ref, owner, repository)}

        {:error, %GitCore.Error{kind: :path_not_found}} ->
          {:cont, {nil, []}}

        {:error, error} ->
          {:halt, {{:unavailable, error}, []}}
      end
    end)
  end

  defp render_readme_blob(git_core, blob, readme_path, selected_ref, owner, repository) do
    if blob.binary or blob.non_utf8 or not is_binary(blob.data) or not String.valid?(blob.data) do
      release_leases([{git_core, blob}])
      {{:unavailable, :non_renderable}, []}
    else
      try do
        html =
          RepositoryMarkdown.render(blob.data,
            path: readme_path,
            owner: owner.username,
            repository: repository.slug,
            ref: selected_ref
          )

        {{:ok, %{path: readme_path, blob: blob, html: html}}, [{git_core, blob}]}
      catch
        _, _ ->
          release_leases([{git_core, blob}])
          {{:unavailable, :render_failed}, []}
      end
    end
  end

  defp read_blob_result(context) do
    case context.git_core.read_blob(
           context.path,
           context.snapshot.oid,
           context.repository_path,
           limit: @inline_blob_limit
         ) do
      {:ok, blob} ->
        {:ok,
         %RepositoryPage.Result{
           kind: :blob,
           chrome: context.chrome,
           content: %RepositoryPage.Blob{path: context.repository_path, blob: blob},
           leases: [{context.git_core, blob}]
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp with_context(repository, owner, viewer, route, opts, fun) do
    git_core = Keyword.get(opts, :git_core, GitCore)
    path = ForgeRepos.absolute_storage_path(repository)

    case load_context(repository, owner, viewer, route, path, git_core) do
      {:ok, context} -> fun.(context)
      {:page, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  defp with_optional_chrome_context(
         repository,
         owner,
         viewer,
         selector,
         resolve_snapshot?,
         opts,
         fun
       ) do
    git_core = Keyword.get(opts, :git_core, GitCore)
    path = ForgeRepos.absolute_storage_path(repository)
    selected_ref = selector_full_name(repository, selector)

    with {:ok, ref_summary} <- git_core.ref_summary(path, selected_ref: selected_ref) do
      cond do
        empty?(ref_summary) ->
          {:ok, empty_result(repository, owner, viewer, ref_summary, path, git_core)}

        true ->
          with {:ok, snapshot} <-
                 optional_chrome_snapshot(
                   repository,
                   selector,
                   ref_summary,
                   path,
                   git_core,
                   resolve_snapshot?
                 ) do
            fun.(%{
              path: path,
              snapshot: snapshot,
              git_core: git_core,
              chrome: chrome(repository, owner, viewer, ref_summary, snapshot)
            })
          end
      end
    end
  end

  defp optional_chrome_snapshot(
         _repository,
         _selector,
         _ref_summary,
         _path,
         _git_core,
         false
       ),
       do: {:ok, nil}

  defp optional_chrome_snapshot(repository, nil, ref_summary, path, git_core, true) do
    selector = default_selector(repository)

    if ref_present?(ref_summary, selector.full_name) do
      git_core.resolve_snapshot(path, selector)
    else
      {:ok, nil}
    end
  end

  defp optional_chrome_snapshot(
         _repository,
         %GitCore.RefSelector{} = selector,
         _ref_summary,
         path,
         git_core,
         true
       ) do
    git_core.resolve_snapshot(path, selector)
  end

  defp load_context(repository, owner, viewer, route, path, git_core)
       when is_list(route) and route != [] do
    with {:ok, {ref_summary, selector, repository_path}} <-
           git_core.ref_summary_for_route(path, route) do
      finish_context(
        repository,
        owner,
        viewer,
        ref_summary,
        selector,
        repository_path,
        path,
        git_core,
        false
      )
    end
  end

  defp load_context(repository, owner, viewer, {selector, repository_path}, path, git_core)
       when is_struct(selector, GitCore.RefSelector) and is_binary(repository_path) do
    with {:ok, ref_summary} <-
           git_core.ref_summary(path, selected_ref: selector.full_name) do
      finish_context(
        repository,
        owner,
        viewer,
        ref_summary,
        selector,
        repository_path,
        path,
        git_core,
        false
      )
    end
  end

  defp load_context(repository, owner, viewer, selector, path, git_core)
       when is_nil(selector) or is_struct(selector, GitCore.RefSelector) do
    selected_ref = selector_full_name(repository, selector)

    with {:ok, ref_summary} <- git_core.ref_summary(path, selected_ref: selected_ref) do
      finish_context(
        repository,
        owner,
        viewer,
        ref_summary,
        selector || default_selector(repository),
        "",
        path,
        git_core,
        is_nil(selector)
      )
    end
  end

  defp finish_context(
         repository,
         owner,
         viewer,
         ref_summary,
         selector,
         repository_path,
         path,
         git_core,
         configured_default?
       ) do
    cond do
      empty?(ref_summary) ->
        {:page, empty_result(repository, owner, viewer, ref_summary, path, git_core)}

      configured_default? and not ref_present?(ref_summary, selector.full_name) ->
        {:page, missing_default_result(repository, owner, viewer, ref_summary)}

      true ->
        case git_core.resolve_snapshot(path, selector) do
          {:ok, snapshot} ->
            {:ok,
             %{
               path: path,
               repository_path: repository_path,
               snapshot: snapshot,
               git_core: git_core,
               chrome: chrome(repository, owner, viewer, ref_summary, snapshot)
             }}

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp empty_result(repository, owner, viewer, ref_summary, path, git_core) do
    %RepositoryPage.Result{
      kind: :empty,
      chrome: chrome(repository, owner, viewer, ref_summary, nil),
      content: %RepositoryPage.Empty{
        write_access: write_access?(viewer, repository),
        disk_usage: optional(git_core.repository_disk_usage(path, []))
      }
    }
  end

  defp missing_default_result(repository, owner, viewer, ref_summary) do
    configured_ref = default_ref(repository)

    %RepositoryPage.Result{
      kind: :missing_default,
      chrome: chrome(repository, owner, viewer, ref_summary, nil),
      content: %RepositoryPage.MissingDefault{configured_ref: configured_ref}
    }
  end

  defp chrome(repository, owner, viewer, ref_summary, snapshot) do
    %RepositoryPage.Chrome{
      owner: owner,
      repository: repository,
      viewer: viewer,
      ref_summary: ref_summary,
      snapshot: snapshot,
      clone: clone(repository, owner, viewer)
    }
  end

  defp clone(repository, owner, viewer) do
    https_url = ForgeRepos.http_clone_url(repository, owner)

    ssh_url =
      case viewer do
        %User{kind: :user, state: :active} = actor ->
          if Fornacast.Access.authorize(actor, :repository_read, repository) == :ok,
            do: ForgeRepos.ssh_clone_url(repository, owner, actor)

        _ ->
          nil
      end

    push_commands =
      if write_access?(viewer, repository) do
        clone_url = ssh_url || https_url

        [
          "git init",
          "git remote add origin #{clone_url}",
          "git branch -M #{repository.default_branch}",
          "git push -u origin #{repository.default_branch}"
        ]
      else
        []
      end

    %RepositoryPage.Clone{
      https_url: https_url,
      ssh_url: ssh_url,
      push_commands: push_commands
    }
  end

  defp result(kind, chrome, content) do
    {:ok, %RepositoryPage.Result{kind: kind, chrome: chrome, content: content}}
  end

  defp default_selector(repository) do
    %GitCore.RefSelector{kind: :branch, full_name: default_ref(repository)}
  end

  defp selector_full_name(repository, nil), do: default_ref(repository)
  defp selector_full_name(_repository, %GitCore.RefSelector{full_name: full_name}), do: full_name

  defp default_ref(%Repository{default_branch: "refs/heads/" <> _ = full_name}), do: full_name

  defp default_ref(%Repository{default_branch: default_branch}) do
    "refs/heads/" <> default_branch
  end

  defp missing_configured_default?(repository, nil, ref_summary) do
    not ref_present?(ref_summary, default_ref(repository))
  end

  defp missing_configured_default?(_repository, _selector, _ref_summary), do: false

  defp ref_present?(ref_summary, full_name) do
    Enum.any?(ref_summary.branches ++ ref_summary.tags, &(&1.name == full_name))
  end

  defp empty?(%GitCore.RefSummary{branch_count: 0, tag_count: 0}), do: true
  defp empty?(%GitCore.RefSummary{}), do: false

  defp optional({:ok, value}), do: {:ok, value}
  defp optional({:error, error}), do: {:unavailable, error}

  defp write_access?(viewer, repository) do
    Fornacast.Access.authorize(viewer, :repository_write, repository) == :ok
  end

  defp release_leases(leases) do
    Enum.each(leases, fn {git_core, blob} ->
      try do
        git_core.release_blob(blob)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end
end
