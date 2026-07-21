defmodule FornacastAPI.Serializer do
  @modules %{
    "2022-11-28" => FornacastAPI.Serializers.V2022_11_28,
    "2026-03-10" => FornacastAPI.Serializers.V2026_03_10
  }

  def render(version, resource, value, opts \\ []) when is_atom(resource) do
    @modules
    |> Map.fetch!(version)
    |> apply(:render, [resource, value, opts])
  end
end

defmodule FornacastAPI.Serializer.Fields do
  alias ForgeAccounts.{AccountView, Organization}
  alias FornacastAPI.URL

  @maximum_repository_size 2_147_483_647

  def simple_user(value) do
    login = fetch!(value, :username)
    id = fetch!(value, :id)
    type = account_type(value)
    api_url = URL.user(login)
    profile_url = URL.web("/#{segment(login)}")

    %{
      avatar_url: profile_url,
      events_url: api_url <> "/events{/privacy}",
      followers_url: api_url <> "/followers",
      following_url: api_url <> "/following{/other_user}",
      gists_url: api_url <> "/gists{/gist_id}",
      gravatar_id: nil,
      html_url: profile_url,
      id: id,
      login: login,
      node_id: node_id(type, id),
      organizations_url: api_url <> "/orgs",
      received_events_url: api_url <> "/received_events",
      repos_url: api_url <> "/repos",
      site_admin: get(value, :role, :user) == :admin,
      starred_url: api_url <> "/starred{/owner}{/repo}",
      subscriptions_url: api_url <> "/subscriptions",
      type: type,
      url: api_url
    }
  end

  def public_user(value) do
    view = AccountView.validate_user!(value)
    account = view.account

    Map.merge(simple_user(account), %{
      bio: get(account, :description),
      blog: nil,
      company: nil,
      created_at: timestamp(fetch!(account, :inserted_at)),
      email: nil,
      followers: 0,
      following: 0,
      hireable: nil,
      location: nil,
      name: get(account, :display_name),
      public_gists: 0,
      public_repos: view.public_repos,
      updated_at: timestamp(fetch!(account, :updated_at))
    })
  end

  def private_user(value) do
    view = AccountView.validate_user!(value)

    Map.merge(public_user(value), %{
      collaborators: 0,
      disk_usage: 0,
      email: get(view.account, :email),
      owned_private_repos: view.private_repos,
      private_gists: 0,
      total_private_repos: view.private_repos,
      two_factor_authentication: view.two_factor_authentication
    })
  end

  def organization_simple(%Organization{kind: :organization} = account) do
    login = fetch!(account, :username)
    id = fetch!(account, :id)
    api_url = URL.organization(login)

    %{
      avatar_url: URL.web("/#{segment(login)}"),
      description: get(account, :description),
      events_url: api_url <> "/events",
      hooks_url: api_url <> "/hooks",
      id: id,
      issues_url: api_url <> "/issues",
      login: login,
      members_url: api_url <> "/members{/member}",
      node_id: node_id("Organization", id),
      public_members_url: api_url <> "/public_members{/member}",
      repos_url: api_url <> "/repos",
      url: api_url
    }
  end

  def organization_simple(_value) do
    raise ArgumentError, "expected a correctly typed ForgeAccounts.Organization"
  end

  def organization_full(value) do
    view = AccountView.validate_organization!(value)
    account = view.account
    login = fetch!(account, :username)

    Map.merge(organization_simple(account), %{
      archived_at: nil,
      created_at: timestamp(fetch!(account, :inserted_at)),
      followers: 0,
      following: 0,
      has_organization_projects: false,
      has_repository_projects: false,
      html_url: URL.web("/#{segment(login)}"),
      name: get(account, :display_name),
      public_gists: 0,
      public_repos: view.public_repos,
      type: "Organization",
      updated_at: timestamp(fetch!(account, :updated_at))
    })
  end

  def repository(value, opts \\ []) do
    repository = fetch!(value, :repository)
    owner = fetch!(value, :owner)
    owner_login = fetch!(owner, :username)
    slug = fetch!(repository, :slug)
    id = fetch!(repository, :id)
    visibility = repository |> fetch!(:visibility) |> to_string()
    api_url = URL.repository(owner_login, slug)
    web_url = URL.web("/#{segment(owner_login)}/#{segment(slug)}")
    clone_url = ForgeRepos.http_clone_url(repository, owner)
    ssh_url = ForgeRepos.ssh_clone_url(repository, owner, Keyword.get(opts, :actor))

    %{
      allow_merge_commit: get(repository, :allow_merge_commit, true),
      allow_rebase_merge: false,
      allow_squash_merge: false,
      archive_url: api_url <> "/{archive_format}{/ref}",
      archived: false,
      assignees_url: api_url <> "/assignees{/user}",
      blobs_url: api_url <> "/git/blobs{/sha}",
      branches_url: api_url <> "/branches{/branch}",
      clone_url: clone_url,
      collaborators_url: api_url <> "/collaborators{/collaborator}",
      comments_url: api_url <> "/comments{/number}",
      commits_url: api_url <> "/commits{/sha}",
      compare_url: api_url <> "/compare/{base}...{head}",
      contents_url: api_url <> "/contents/{+path}",
      contributors_url: api_url <> "/contributors",
      created_at: timestamp(fetch!(repository, :inserted_at)),
      default_branch: fetch!(repository, :default_branch),
      deployments_url: api_url <> "/deployments",
      description: get(repository, :description),
      disabled: false,
      downloads_url: api_url <> "/downloads",
      events_url: api_url <> "/events",
      fork: false,
      forks: 0,
      forks_count: 0,
      forks_url: api_url <> "/forks",
      full_name: owner_login <> "/" <> slug,
      git_commits_url: api_url <> "/git/commits{/sha}",
      git_refs_url: api_url <> "/git/refs{/sha}",
      git_tags_url: api_url <> "/git/tags{/sha}",
      git_url: clone_url,
      has_discussions: false,
      has_downloads: false,
      has_issues: get(repository, :has_issues, true),
      has_pages: false,
      has_projects: false,
      has_wiki: false,
      homepage: nil,
      hooks_url: api_url <> "/hooks",
      html_url: web_url,
      id: id,
      issue_comment_url: api_url <> "/issues/comments{/number}",
      issue_events_url: api_url <> "/issues/events{/number}",
      issues_url: api_url <> "/issues{/number}",
      keys_url: api_url <> "/keys{/key_id}",
      labels_url: api_url <> "/labels{/name}",
      language: nil,
      languages_url: api_url <> "/languages",
      license: nil,
      merges_url: api_url <> "/merges",
      milestones_url: api_url <> "/milestones{/number}",
      mirror_url: nil,
      name: fetch!(repository, :name),
      network_count: 0,
      node_id: node_id("Repository", id),
      notifications_url: api_url <> "/notifications{?since,all,participating}",
      open_issues: 0,
      open_issues_count: 0,
      owner: simple_user(owner),
      permissions: permissions(get(value, :permissions, %{})),
      private: visibility == "private",
      pulls_url: api_url <> "/pulls{/number}",
      pushed_at: timestamp(get(repository, :last_pushed_at)),
      releases_url: api_url <> "/releases{/id}",
      size: bounded_size(get(value, :size_kib, 0)),
      ssh_url: ssh_url,
      stargazers_count: 0,
      stargazers_url: api_url <> "/stargazers",
      statuses_url: api_url <> "/statuses/{sha}",
      subscribers_count: 0,
      subscribers_url: api_url <> "/subscribers",
      subscription_url: api_url <> "/subscription",
      svn_url: clone_url,
      tags_url: api_url <> "/tags",
      teams_url: api_url <> "/teams",
      topics: [],
      trees_url: api_url <> "/git/trees{/sha}",
      updated_at: timestamp(fetch!(repository, :updated_at)),
      url: api_url,
      visibility: visibility,
      watchers: 0,
      watchers_count: 0
    }
  end

  def rate_limit(bucket) do
    %{
      limit: fetch!(bucket, :limit),
      remaining: fetch!(bucket, :remaining),
      reset: fetch!(bucket, :reset),
      used: fetch!(bucket, :used)
    }
  end

  def error(value) do
    %{message: fetch!(value, :message), documentation_url: fetch!(value, :documentation_url)}
    |> maybe_put_errors(get(value, :errors))
  end

  defp maybe_put_errors(body, nil), do: body

  defp maybe_put_errors(body, errors) do
    Map.put(body, :errors, Enum.map(errors, &validation_error/1))
  end

  defp validation_error(error) do
    [:resource, :field, :code, :message]
    |> Enum.reduce(%{}, fn key, entry ->
      case fetch(error, key) do
        {:ok, value} -> Map.put(entry, key, if(key == :code, do: to_string(value), else: value))
        :error -> entry
      end
    end)
  end

  defp permissions(value) do
    %{
      admin: get(value, :admin, false),
      maintain: get(value, :maintain, false),
      pull: get(value, :pull, false),
      push: get(value, :push, false),
      triage: get(value, :triage, false)
    }
  end

  defp bounded_size(size) when is_integer(size),
    do: size |> max(0) |> min(@maximum_repository_size)

  defp bounded_size(_size), do: 0

  defp account_type(value) do
    case get(value, :kind, :user) do
      kind when kind in [:organization, "organization"] -> "Organization"
      _kind -> "User"
    end
  end

  defp node_id(type, id),
    do: Base.url_encode64("#{type}:#{id}", padding: false)

  defp timestamp(nil), do: nil
  defp timestamp(value) when is_binary(value), do: value
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp timestamp(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp fetch!(value, key) do
    case fetch(value, key) do
      {:ok, result} -> result
      :error -> raise KeyError, key: key, term: value
    end
  end

  defp get(value, key, default \\ nil) do
    case fetch(value, key) do
      {:ok, result} -> result
      :error -> default
    end
  end

  defp fetch(value, key) when is_map(value) do
    case Map.fetch(value, key) do
      :error -> Map.fetch(value, Atom.to_string(key))
      result -> result
    end
  end
end
