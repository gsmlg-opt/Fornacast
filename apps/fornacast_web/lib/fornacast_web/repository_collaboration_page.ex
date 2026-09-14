defmodule FornacastWeb.RepositoryCollaborationPage do
  @moduledoc """
  Composes issue, pull, and release domain reads with the shared repository chrome.
  """

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.RepositoryPage

  @collaboration_kinds [
    :issues,
    :issue,
    :pulls,
    :pull,
    :pull_commits,
    :pull_files,
    :releases,
    :release,
    :release_new,
    :release_edit
  ]

  @type result :: {:ok, %RepositoryPage.Result{}} | {:error, term()}

  def decorate(result, opts \\ [])

  def decorate(%RepositoryPage.Result{kind: kind} = result, _opts)
      when kind in @collaboration_kinds,
      do: result

  def decorate(%RepositoryPage.Result{} = result, opts) when is_list(opts) do
    counts = result.chrome.collaboration_counts

    if counts.issues == nil and counts.pull_requests == nil do
      chrome = result.chrome

      put_in(
        result.chrome.collaboration_counts,
        collaboration_counts(chrome.repository, chrome.owner, chrome.viewer, opts)
      )
    else
      result
    end
  end

  @spec issues(Repository.t(), User.t(), User.t() | nil, map(), keyword()) :: result()
  def issues(repository, owner, viewer, filters, opts \\ [])
      when is_map(filters) and is_list(opts) do
    issues = Keyword.get(opts, :forge_issues, ForgeIssues)

    with {:ok, page} <- issues.list(viewer, owner.username, repository.slug, filters) do
      compose(repository, owner, viewer, :issues, %{issues: page, filters: filters}, opts)
    end
  end

  @spec issue(Repository.t(), User.t(), User.t() | nil, pos_integer(), keyword()) :: result()
  def issue(repository, owner, viewer, number, opts \\ [])
      when is_integer(number) and number > 0 and is_list(opts) do
    issues = Keyword.get(opts, :forge_issues, ForgeIssues)

    with {:ok, issue} <- issues.get(viewer, owner.username, repository.slug, number),
         {:ok, comments} <-
           issues.list_comments(viewer, owner.username, repository.slug, number, %{
             page: 1,
             per_page: 100
           }) do
      compose(repository, owner, viewer, :issue, %{issue: issue, comments: comments}, opts)
    end
  end

  @spec pulls(Repository.t(), User.t(), User.t() | nil, map(), keyword()) :: result()
  def pulls(repository, owner, viewer, filters, opts \\ [])
      when is_map(filters) and is_list(opts) do
    pulls = Keyword.get(opts, :forge_pulls, ForgePulls)

    with {:ok, page} <- pulls.list_pull_requests(repository, viewer, Map.to_list(filters)) do
      compose(repository, owner, viewer, :pulls, %{pulls: page, filters: filters}, opts)
    end
  end

  @spec pull(Repository.t(), User.t(), User.t() | nil, pos_integer(), keyword()) :: result()
  def pull(repository, owner, viewer, number, opts \\ [])
      when is_integer(number) and number > 0 and is_list(opts) do
    pulls = Keyword.get(opts, :forge_pulls, ForgePulls)
    issues = Keyword.get(opts, :forge_issues, ForgeIssues)

    with {:ok, pull} <- pulls.get_pull_request(repository, number, viewer),
         {:ok, comments} <-
           issues.list_comments(viewer, owner.username, repository.slug, number, %{
             page: 1,
             per_page: 100
           }) do
      compose(repository, owner, viewer, :pull, %{pull: pull, comments: comments}, opts)
    end
  end

  @spec pull_commits(Repository.t(), User.t(), User.t() | nil, pos_integer(), map()) :: result()
  def pull_commits(repository, owner, viewer, number, params)
      when is_integer(number) and number > 0 and is_map(params) do
    {opts, domain_opts} = pull_page_options(params)
    pulls = Keyword.get(opts, :forge_pulls, ForgePulls)

    with {:ok, pull} <- pulls.get_pull_request(repository, number, viewer),
         {:ok, commits} <- pulls.list_commits(repository, pull, viewer, domain_opts) do
      compose(repository, owner, viewer, :pull_commits, %{pull: pull, commits: commits}, opts)
    end
  end

  @spec pull_files(Repository.t(), User.t(), User.t() | nil, pos_integer(), map()) :: result()
  def pull_files(repository, owner, viewer, number, params)
      when is_integer(number) and number > 0 and is_map(params) do
    {opts, domain_opts} = pull_page_options(params)
    pulls = Keyword.get(opts, :forge_pulls, ForgePulls)

    with {:ok, pull} <- pulls.get_pull_request(repository, number, viewer),
         {:ok, files} <- pulls.changed_files(repository, pull, viewer, domain_opts) do
      compose(repository, owner, viewer, :pull_files, %{pull: pull, files: files}, opts)
    end
  end

  @spec releases(Repository.t(), User.t(), User.t() | nil, map(), keyword()) :: result()
  def releases(repository, owner, viewer, filters, opts \\ [])
      when is_map(filters) and is_list(opts) do
    releases = Keyword.get(opts, :forge_releases, ForgeReleases)

    with {:ok, page} <- releases.list(viewer, owner.username, repository.slug, filters) do
      compose(
        repository,
        owner,
        viewer,
        :releases,
        %{
          releases: page,
          can_create: Fornacast.Access.allowed?(viewer, :repository_write, repository)
        },
        opts
      )
    end
  end

  @spec release(Repository.t(), User.t(), User.t() | nil, pos_integer(), keyword()) :: result()
  def release(repository, owner, viewer, id, opts \\ [])
      when is_integer(id) and id > 0 and is_list(opts) do
    releases = Keyword.get(opts, :forge_releases, ForgeReleases)

    with {:ok, release} <- releases.get(viewer, owner.username, repository.slug, id) do
      compose(repository, owner, viewer, :release, %{release: release}, opts)
    end
  end

  @spec release_by_tag(Repository.t(), User.t(), User.t() | nil, String.t(), keyword()) ::
          result()
  def release_by_tag(repository, owner, viewer, tag, opts \\ [])
      when is_binary(tag) and is_list(opts) do
    releases = Keyword.get(opts, :forge_releases, ForgeReleases)

    with {:ok, release} <- releases.get_by_tag(viewer, owner.username, repository.slug, tag) do
      compose(repository, owner, viewer, :release, %{release: release}, opts)
    end
  end

  @spec release_form(
          Repository.t(),
          User.t(),
          User.t(),
          :new | {:edit, pos_integer()},
          map(),
          list(),
          keyword()
        ) :: result()
  def release_form(repository, owner, viewer, mode, values, errors, opts \\ [])

  def release_form(repository, owner, %User{} = viewer, :new, values, errors, opts)
      when is_map(values) and is_list(errors) and is_list(opts) do
    if Fornacast.Access.allowed?(viewer, :repository_write, repository) do
      compose(
        repository,
        owner,
        viewer,
        :release_new,
        %{release: nil, values: values, errors: errors},
        opts
      )
    else
      {:error, :forbidden}
    end
  end

  def release_form(
        repository,
        owner,
        %User{} = viewer,
        {:edit, id},
        values,
        errors,
        opts
      )
      when is_integer(id) and id > 0 and is_map(values) and is_list(errors) and is_list(opts) do
    releases = Keyword.get(opts, :forge_releases, ForgeReleases)

    with {:ok, release} <- releases.get(viewer, owner.username, repository.slug, id),
         true <- release.capabilities.can_edit do
      values = if values == %{}, do: release_values(release), else: values

      compose(
        repository,
        owner,
        viewer,
        :release_edit,
        %{release: release, values: values, errors: errors},
        opts
      )
    else
      false -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  def release_form(_repository, _owner, _viewer, _mode, _values, _errors, _opts),
    do: {:error, :forbidden}

  defp compose(repository, owner, viewer, kind, content, opts) do
    repository_page = Keyword.get(opts, :repository_page, RepositoryPage)
    git_core = Keyword.get(opts, :git_core, GitCore)

    with {:ok, result} <-
           repository_page.collaboration(repository, owner, viewer, kind, content,
             git_core: git_core
           ) do
      counts = collaboration_counts(repository, owner, viewer, opts)
      {:ok, put_in(result.chrome.collaboration_counts, counts)}
    end
  end

  defp collaboration_counts(repository, owner, viewer, opts) do
    issues = Keyword.get(opts, :forge_issues, ForgeIssues)

    case issues.open_counts(viewer, owner.username, repository.slug) do
      {:ok, %{issues: issues, pull_requests: pulls}} ->
        %{issues: issues, pull_requests: pulls}

      {:error, _reason} ->
        %{issues: nil, pull_requests: nil}
    end
  end

  defp release_values(release) do
    %{
      "tag_name" => release.tag_name,
      "name" => release.name,
      "body" => release.body,
      "target_commitish" => release.target_commitish,
      "draft" => release.draft,
      "prerelease" => release.prerelease
    }
  end

  defp pull_page_options(params) do
    module_keys = [:forge_issues, :forge_pulls, :git_core, :repository_page]
    opts = params |> Map.take(module_keys) |> Map.to_list()
    domain_opts = params |> Map.drop(module_keys) |> Map.to_list()
    {opts, domain_opts}
  end
end
