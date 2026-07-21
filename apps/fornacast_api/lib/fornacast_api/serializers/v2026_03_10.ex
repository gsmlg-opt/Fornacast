defmodule FornacastAPI.Serializers.V2026_03_10 do
  alias FornacastAPI.Serializer.Fields

  @simple_user_keys ~w(
    avatar_url events_url followers_url following_url gists_url gravatar_id html_url id login
    node_id organizations_url received_events_url repos_url site_admin starred_url subscriptions_url
    type url
  )a
  @public_user_keys @simple_user_keys ++
                      ~w(bio blog company created_at email followers following hireable location name
                         public_gists public_repos updated_at)a
  @private_user_keys @public_user_keys ++
                       ~w(collaborators disk_usage owned_private_repos private_gists
                          total_private_repos two_factor_authentication)a
  @organization_simple_keys ~w(
    avatar_url description events_url hooks_url id issues_url login members_url node_id
    public_members_url repos_url url
  )a
  @organization_full_keys @organization_simple_keys ++
                            ~w(archived_at created_at followers following has_organization_projects
                               has_repository_projects html_url name public_gists public_repos type
                               updated_at)a

  @minimal_repository_keys ~w(
    archive_url archived assignees_url blobs_url branches_url clone_url collaborators_url
    comments_url commits_url compare_url contents_url contributors_url created_at default_branch
    deployments_url description disabled downloads_url events_url fork forks forks_count forks_url
    full_name git_commits_url git_refs_url git_tags_url git_url has_discussions has_issues has_pages
    has_projects has_wiki homepage hooks_url html_url id issue_comment_url issue_events_url issues_url
    keys_url labels_url language languages_url license merges_url milestones_url mirror_url name
    network_count node_id notifications_url open_issues open_issues_count owner permissions private
    pulls_url pushed_at releases_url size ssh_url stargazers_count stargazers_url statuses_url
    subscribers_count subscribers_url subscription_url svn_url tags_url teams_url topics trees_url
    updated_at url visibility watchers watchers_count
  )a

  @repository_keys (@minimal_repository_keys ++
                      ~w(allow_merge_commit allow_rebase_merge allow_squash_merge)a) --
                     ~w(network_count subscribers_count)a

  @full_repository_keys @repository_keys ++ ~w(network_count subscribers_count)a

  def render(:simple_user, value, _opts),
    do: value |> Fields.simple_user() |> Map.take(@simple_user_keys)

  def render(:public_user, value, _opts),
    do: value |> Fields.public_user() |> Map.take(@public_user_keys)

  def render(:private_user, value, _opts),
    do: value |> Fields.private_user() |> Map.take(@private_user_keys)

  def render(:organization_simple, value, _opts),
    do: value |> Fields.organization_simple() |> Map.take(@organization_simple_keys)

  def render(:organization_full, value, _opts),
    do: value |> Fields.organization_full() |> Map.take(@organization_full_keys)

  def render(:minimal_repository, value, opts),
    do: value |> Fields.repository(opts) |> Map.take(@minimal_repository_keys)

  def render(:repository, value, opts),
    do: value |> Fields.repository(opts) |> Map.take(@repository_keys)

  def render(:full_repository, value, opts),
    do: value |> Fields.repository(opts) |> Map.take(@full_repository_keys)

  def render(:rate_limit, bucket, _opts) do
    %{resources: %{core: Fields.rate_limit(bucket)}}
  end

  def render(:error, value, _opts), do: Fields.error(value)

  def render(resource, _value, _opts) do
    raise ArgumentError, "unsupported serializer resource: #{inspect(resource)}"
  end
end
