defmodule FornacastWeb.RepositoryView do
  @moduledoc "Projects authorized repository page results into plain presentation data."
  alias FornacastWeb.{RepositoryHTML, RepositoryPage}
  import FornacastWeb.RepositoryPaths

  def frame(%RepositoryPage.Result{} = result, active) do
    chrome = result.chrome
    summary = chrome.ref_summary
    repository = chrome.repository

    %{
      kind: result.kind,
      header: %{
        owner: RepositoryHTML.owner_name(result),
        owner_href: owner_path(chrome),
        name: RepositoryHTML.repository_name(result),
        name_href: repository_base(chrome),
        visibility: RepositoryHTML.visibility_label(result),
        default_ref: RepositoryHTML.selected_ref_label(result),
        configured_ref: RepositoryHTML.configured_ref_label(result),
        description: repository.description,
        short_oid: chrome.snapshot && RepositoryHTML.short_oid(chrome.snapshot.oid),
        last_pushed_at:
          repository.last_pushed_at && RepositoryHTML.format_time(repository.last_pushed_at)
      },
      navigation: navigation(result, active),
      show_toolbar: result.kind in [:tree, :blob, :commits, :commit, :search],
      toolbar: %{
        options:
          Enum.map(summary.branches ++ summary.tags, &{&1.name, RepositoryHTML.ref_label(&1)}),
        selected: selected_or_default_full_ref(chrome),
        refs_truncated: summary.refs_truncated,
        action: repository_base(chrome),
        branches_href: refs_path(chrome, :branch),
        tags_href: refs_path(chrome, :tag),
        search_href: search_path(chrome, :path)
      },
      clone: %{
        title: if(result.kind == :empty, do: "Set up repository", else: "Clone repository"),
        https_url: chrome.clone.https_url,
        ssh_url: chrome.clone.ssh_url,
        commands: clone_commands(result)
      }
    }
  end

  defp navigation(result, active) do
    chrome = result.chrome

    [
      {:code, "Code", code_path(chrome), "code-tags", nil},
      {:commits, "Commits", commits_path(chrome), "source-commit", commit_count(result)},
      {:branches, "Branches", refs_path(chrome, :branch), "source-branch",
       chrome.ref_summary.branch_count},
      {:tags, "Tags", refs_path(chrome, :tag), "tag-outline", chrome.ref_summary.tag_count},
      {:releases, "Releases", releases_path(chrome), "tag-outline", nil},
      {:issues, "Issues", issues_path(chrome), "alert-circle-outline",
       chrome.collaboration_counts.issues},
      {:pulls, "Pull Requests", pulls_path(chrome), "source-pull",
       chrome.collaboration_counts.pull_requests}
    ]
    |> Enum.map(fn {key, label, href, icon, count} ->
      %{label: label, href: href, icon: icon, count: count, active: key == active}
    end)
  end

  defp commit_count(%RepositoryPage.Result{
         kind: :code,
         content: %RepositoryPage.Code{commit_summary: %{count: count}}
       }),
       do: count

  defp commit_count(%RepositoryPage.Result{kind: :empty}), do: 0
  defp commit_count(_result), do: nil

  defp clone_commands(%RepositoryPage.Result{
         kind: :empty,
         content: %RepositoryPage.Empty{write_access: true},
         chrome: %{clone: clone}
       }) do
    Enum.map(clone.push_commands, &{push_command_label(&1), &1})
  end

  defp clone_commands(%RepositoryPage.Result{kind: :empty}), do: []

  defp clone_commands(%RepositoryPage.Result{chrome: %{clone: clone}}) do
    [{"Clone", "git clone #{clone.https_url}"}]
  end

  defp push_command_label("git init"), do: "Initialize"
  defp push_command_label("git remote add origin " <> _url), do: "Add remote"
  defp push_command_label("git branch -M " <> _ref), do: "Set default branch"
  defp push_command_label("git push " <> _rest), do: "Push"
  defp push_command_label(_command), do: "Command"
end
