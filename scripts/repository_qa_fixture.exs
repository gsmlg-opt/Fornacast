defmodule Fornacast.RepositoryQAFixture do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{APIKey, OrganizationMember, SSHKey, User}
  alias ForgeRepos.{Collaborator, Repository}
  alias Fornacast.{AuditEvent, Repo}

  @password "correct horse battery staple"
  @owner_username "qa-owner"
  @reader_username "qa-reader"
  @private_slug "qa-populated-private"
  @search_query "FORNACAST_QA_MATCH"
  @tag_name "qa-v1.0.0"
  @pushed_at ~U[2026-01-03 03:04:05Z]

  @accounts [
    %{username: @owner_username, email: "qa-owner@fornacast.invalid"},
    %{username: @reader_username, email: "qa-reader@fornacast.invalid"},
    %{username: "qa-denied", email: "qa-denied@fornacast.invalid"}
  ]

  @repositories [
    %{
      slug: "qa-populated-public",
      name: "QA Populated Public",
      description: "Deterministic public repository for browser QA.",
      visibility: :public,
      populated?: true
    },
    %{
      slug: "qa-empty-public",
      name: "QA Empty Public",
      description: "Empty public repository for browser QA.",
      visibility: :public,
      populated?: false
    },
    %{
      slug: @private_slug,
      name: "QA Populated Private",
      description: "Deterministic private repository for authorization QA.",
      visibility: :private,
      populated?: true
    }
  ]

  @repository_slugs Enum.map(@repositories, & &1.slug)

  def run([]) do
    cleanup!(print?: false)

    users = create_users!()
    owner = Map.fetch!(users, @owner_username)
    repositories = create_repositories!(owner)

    populated =
      @repositories
      |> Enum.filter(& &1.populated?)
      |> Enum.map(&Map.fetch!(repositories, &1.slug))

    fixture = populate_repositories!(populated)

    private_repository = Map.fetch!(repositories, @private_slug)
    reader = Map.fetch!(users, @reader_username)
    insert_reader_collaboration!(private_repository, reader)

    Enum.each(populated, fn repository ->
      {:ok, _repository} = ForgeRepos.mark_pushed(repository, @pushed_at)
    end)

    print_setup_summary(fixture)
  end

  def run(["--cleanup"]) do
    cleanup!(print?: true)
  end

  def run(["--", "--cleanup"]) do
    cleanup!(print?: true)
  end

  def run(arguments) do
    raise ArgumentError,
          "usage: mix run scripts/repository_qa_fixture.exs [-- --cleanup], got: " <>
            inspect(arguments)
  end

  defp create_users! do
    @accounts
    |> Enum.map(fn account ->
      account
      |> Map.merge(%{password: @password, state: :active})
      |> ForgeAccounts.create_user()
      |> unwrap!("create user #{account.username}")
    end)
    |> Map.new(&{&1.username, &1})
  end

  defp create_repositories!(owner) do
    @repositories
    |> Enum.map(fn repository ->
      attrs = Map.drop(repository, [:populated?])

      created =
        owner
        |> ForgeRepos.create_repository(Map.put(attrs, :default_branch, "main"))
        |> unwrap!("create repository #{@owner_username}/#{repository.slug}")

      {created.slug, created}
    end)
    |> Map.new()
  end

  defp insert_reader_collaboration!(repository, reader) do
    %Collaborator{}
    |> Collaborator.changeset(%{
      repository_id: repository.id,
      user_id: reader.id,
      role: :read
    })
    |> Repo.insert()
    |> unwrap!("grant #{@reader_username} read access to #{@private_slug}")
  end

  defp populate_repositories!(repositories) do
    worktree =
      Path.join(
        System.tmp_dir!(),
        "fornacast-repository-qa-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(worktree)

    try do
      git!(["init", "--object-format=sha1", worktree])
      write_initial_tree!(worktree)
      git!(["-C", worktree, "add", "."])
      git!(["-C", worktree, "commit", "-m", "Seed deterministic QA repository"], commit_env(1))
      git!(["-C", worktree, "branch", "-M", "main"])

      first_commit = git!(["-C", worktree, "rev-parse", "HEAD"])
      git!(["-C", worktree, "branch", "feature/slash", first_commit])

      write_second_commit!(worktree)
      git!(["-C", worktree, "add", "."])
      git!(["-C", worktree, "commit", "-m", "Exercise repository diff views"], commit_env(2))

      git!(
        ["-C", worktree, "tag", "-a", @tag_name, first_commit, "-m", "QA fixture v1.0.0"],
        tag_env()
      )

      fixture = verify_worktree!(worktree, first_commit)
      push_to_repositories!(worktree, repositories)
      fixture
    after
      File.rm_rf!(worktree)
    end
  end

  defp write_initial_tree!(worktree) do
    write!(
      worktree,
      "README.md",
      """
      # Fornacast repository QA

      [Read the QA guide](docs/guide.md)

      ![One-pixel raster fixture](assets/pixel.png)

      ![SVG fixture](assets/diagram.svg)

      Search for `#{@search_query}` to exercise deterministic result truncation.
      """
    )

    write!(
      worktree,
      "docs/guide.md",
      """
      # QA guide

      This relative document is linked from the repository README.
      """
    )

    write!(
      worktree,
      "assets/diagram.svg",
      """
      <svg xmlns="http://www.w3.org/2000/svg" width="160" height="64" viewBox="0 0 160 64">
        <rect width="160" height="64" rx="8" fill="#4338ca"/>
        <text x="80" y="38" text-anchor="middle" fill="white">Fornacast QA</text>
      </svg>
      """
    )

    write!(
      worktree,
      "assets/pixel.png",
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
    )

    write!(worktree, "notes.txt", "Deterministic text blob for raw and source views.\n")
    write!(worktree, "binary.bin", <<0, 1, 2, 3, 255, 254, 128, 0, 10, 13>>)
    write!(worktree, "nested/deep/example.txt", "Nested fixture content.\n")

    Enum.each(1..125, fn index ->
      filename = "qa-match-#{pad(index)}.txt"
      write!(worktree, filename, "#{@search_query} deterministic result #{pad(index)}\n")
    end)

    Enum.each(126..205, fn index ->
      filename = "tree-entry-#{pad(index)}.txt"
      write!(worktree, filename, "Deterministic tree pagination entry #{pad(index)}\n")
    end)
  end

  defp write_second_commit!(worktree) do
    File.write!(
      Path.join(worktree, "README.md"),
      "\nThe second commit provides a real multi-file diff.\n",
      [:append]
    )

    File.write!(
      Path.join([worktree, "docs", "guide.md"]),
      "\nUse the branch and tag selectors to exercise ref-aware navigation.\n",
      [:append]
    )

    File.write!(
      Path.join(worktree, "qa-match-001.txt"),
      "Second-commit change for diff rendering.\n",
      [:append]
    )

    write!(
      worktree,
      "nested/deep/second-commit.txt",
      "Added by the second deterministic commit.\n"
    )
  end

  defp verify_worktree!(worktree, first_commit) do
    tip = git!(["-C", worktree, "rev-parse", "HEAD"])
    assert_equal!(git!(["-C", worktree, "rev-list", "--count", "main"]), "2", "commit count")

    assert_equal!(
      git!(["-C", worktree, "rev-parse", "feature/slash"]),
      first_commit,
      "feature/slash target"
    )

    assert_equal!(
      git!(["-C", worktree, "cat-file", "-t", "refs/tags/#{@tag_name}"]),
      "tag",
      "annotated tag type"
    )

    root_entries =
      ["-C", worktree, "ls-tree", "--name-only", "main"]
      |> git_lines!()
      |> length()

    search_matches =
      ["-C", worktree, "grep", "-l", @search_query, "main"]
      |> git_lines!()
      |> length()

    changed_files =
      ["-C", worktree, "diff-tree", "--no-commit-id", "--name-only", "-r", tip]
      |> git_lines!()
      |> length()

    assert_greater_than!(root_entries, 200, "root direct-child count")
    assert_greater_than!(search_matches, 100, "search-match file count")
    assert_greater_than!(changed_files, 1, "tip diff file count")

    %{
      first_commit: first_commit,
      tip: tip,
      root_entries: root_entries,
      search_matches: search_matches,
      changed_files: changed_files
    }
  end

  defp push_to_repositories!(worktree, repositories) do
    Enum.with_index(repositories, 1)
    |> Enum.each(fn {repository, index} ->
      remote = "qa#{index}"
      storage_path = ForgeRepos.absolute_storage_path(repository)

      git!(["-C", worktree, "remote", "add", remote, storage_path])

      git!([
        "-C",
        worktree,
        "push",
        remote,
        "refs/heads/main:refs/heads/main",
        "refs/heads/feature/slash:refs/heads/feature/slash",
        "refs/tags/#{@tag_name}:refs/tags/#{@tag_name}"
      ])

      git!(["--git-dir", storage_path, "symbolic-ref", "HEAD", "refs/heads/main"])
    end)
  end

  defp cleanup!(options) do
    accounts = existing_fixture_accounts!()
    owned_repositories = owned_repositories(accounts)
    validate_owned_repositories!(accounts, owned_repositories)

    fixture_repositories =
      Enum.filter(owned_repositories, fn repository ->
        repository.owner_user_id == account_id(accounts, @owner_username) and
          repository.slug in @repository_slugs
      end)

    validate_organization_memberships!(accounts)
    collaborators = validate_cleanup_dependencies!(accounts, fixture_repositories)

    Enum.each(fixture_repositories, fn repository ->
      repository
      |> ForgeRepos.absolute_storage_path()
      |> File.rm_rf!()
    end)

    Repo.transaction(fn ->
      nilify_audit_actors!(accounts)
      Enum.each(collaborators, &Repo.delete!/1)
      Enum.each(fixture_repositories, &Repo.delete!/1)
      Enum.each(accounts, &Repo.delete!/1)
    end)
    |> unwrap_transaction!("clean up repository QA fixture")

    if Keyword.fetch!(options, :print?) do
      IO.puts("Removed repository QA accounts, repositories, and storage.")
    end
  end

  defp existing_fixture_accounts! do
    Enum.flat_map(@accounts, fn expected ->
      case ForgeAccounts.get_account_by_username(expected.username) do
        nil ->
          []

        %User{kind: :user, role: :user, state: :active, email: email} = user
        when email == expected.email ->
          [user]

        %User{} = account ->
          raise """
          Refusing to reset #{expected.username}: the existing account does not match the QA \
          fixture identity (kind=#{inspect(account.kind)}, email=#{inspect(account.email)}).
          """
      end
    end)
  end

  defp owned_repositories([]), do: []

  defp owned_repositories(accounts) do
    account_ids = Enum.map(accounts, & &1.id)
    Repo.all(from repository in Repository, where: repository.owner_user_id in ^account_ids)
  end

  defp validate_owned_repositories!(accounts, repositories) do
    accounts_by_id = Map.new(accounts, &{&1.id, &1.username})

    unexpected =
      Enum.reject(repositories, fn repository ->
        Map.fetch!(accounts_by_id, repository.owner_user_id) == @owner_username and
          repository.slug in @repository_slugs
      end)

    unless unexpected == [] do
      labels =
        Enum.map_join(unexpected, ", ", fn repository ->
          "#{Map.fetch!(accounts_by_id, repository.owner_user_id)}/#{repository.slug}"
        end)

      raise "Refusing cleanup because QA accounts own repositories outside the fixture: #{labels}"
    end
  end

  defp validate_organization_memberships!([]), do: :ok

  defp validate_organization_memberships!(accounts) do
    account_ids = Enum.map(accounts, & &1.id)

    if Repo.exists?(
         from membership in OrganizationMember,
           where: membership.user_id in ^account_ids
       ) do
      raise "Refusing cleanup because a QA account belongs to an organization"
    end
  end

  defp validate_cleanup_dependencies!(accounts, repositories) do
    account_ids = Enum.map(accounts, & &1.id)
    repository_ids = Enum.map(repositories, & &1.id)

    api_keys = records_for_accounts(APIKey, account_ids)
    ssh_keys = records_for_accounts(SSHKey, account_ids)

    unless api_keys == [] and ssh_keys == [] do
      raise """
      Refusing cleanup because a QA fixture account has API keys or SSH keys. Remove those \
      credentials explicitly before cleanup.
      """
    end

    collaborators =
      records_for_accounts(Collaborator, account_ids) ++
        records_for_repositories(Collaborator, repository_ids)

    collaborators
    |> Enum.uniq_by(& &1.id)
    |> validate_fixture_collaborator!(accounts, repositories)
  end

  defp records_for_accounts(_schema, []), do: []

  defp records_for_accounts(schema, account_ids) do
    Repo.all(from record in schema, where: record.user_id in ^account_ids)
  end

  defp records_for_repositories(_schema, []), do: []

  defp records_for_repositories(schema, repository_ids) do
    Repo.all(from record in schema, where: record.repository_id in ^repository_ids)
  end

  defp validate_fixture_collaborator!([], _accounts, _repositories), do: []

  defp validate_fixture_collaborator!([collaborator], accounts, repositories) do
    reader_id = account_id(accounts, @reader_username)

    private_repository_ids =
      repositories
      |> Enum.filter(&(&1.slug == @private_slug))
      |> Enum.map(& &1.id)

    if collaborator.user_id == reader_id and
         collaborator.repository_id in private_repository_ids and collaborator.role == :read do
      [collaborator]
    else
      raise_unexpected_collaborator!()
    end
  end

  defp validate_fixture_collaborator!(_collaborators, _accounts, _repositories) do
    raise_unexpected_collaborator!()
  end

  defp raise_unexpected_collaborator! do
    raise """
    Refusing cleanup because repository collaborations differ from the optional \
    qa-reader/qa-populated-private/read fixture row.
    """
  end

  defp nilify_audit_actors!([]), do: {0, nil}

  defp nilify_audit_actors!(accounts) do
    account_ids = Enum.map(accounts, & &1.id)

    AuditEvent
    |> where([event], event.actor_user_id in ^account_ids)
    |> Repo.update_all(set: [actor_user_id: nil])
  end

  defp account_id(accounts, username) do
    case Enum.find(accounts, &(&1.username == username)) do
      nil -> nil
      account -> account.id
    end
  end

  defp print_setup_summary(fixture) do
    base_url = Fornacast.Config.base_url()
    public_url = "#{base_url}/#{@owner_username}/qa-populated-public"
    empty_url = "#{base_url}/#{@owner_username}/qa-empty-public"
    private_url = "#{base_url}/#{@owner_username}/#{@private_slug}"
    content_search_url = search_url(public_url, @search_query, :content)
    path_search_url = search_url(public_url, "qa-match", :path)

    IO.puts("""

    Repository QA fixture ready.

    Credentials (local deterministic QA accounts):
      qa-owner  / #{@password}
      qa-reader / #{@password}
      qa-denied / #{@password}

    Routes:
      populated public:  #{public_url}
      empty public:      #{empty_url}
      populated private: #{private_url}
      search truncation: #{content_search_url}
      path search:       #{path_search_url}
      branches:          #{public_url}/branches
      tags:              #{public_url}/tags

    Git contract:
      main tip:          #{fixture.tip}
      first commit:      #{fixture.first_commit}
      root entries:      #{fixture.root_entries}
      search matches:    #{fixture.search_matches}
      tip changed files: #{fixture.changed_files}
      branch:            feature/slash
      annotated tag:     #{@tag_name}

    Private access:
      qa-reader has read-only access; qa-denied has no access.
    """)
  end

  defp search_url(repository_url, query, scope) do
    encoded_query = URI.encode_www_form(query)
    "#{repository_url}/search?q=#{encoded_query}&scope=#{scope}"
  end

  defp write!(root, relative_path, contents) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp pad(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")

  defp git_lines!(arguments) do
    arguments
    |> git!()
    |> String.split("\n", trim: true)
  end

  defp git!(arguments, extra_env \\ []) do
    env =
      %{
        "GIT_AUTHOR_EMAIL" => "qa-fixture@fornacast.invalid",
        "GIT_AUTHOR_NAME" => "Fornacast QA",
        "GIT_COMMITTER_EMAIL" => "qa-fixture@fornacast.invalid",
        "GIT_COMMITTER_NAME" => "Fornacast QA",
        "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_TERMINAL_PROMPT" => "0",
        "LC_ALL" => "C",
        "TZ" => "UTC"
      }
      |> Map.merge(Map.new(extra_env))
      |> Map.to_list()

    case System.cmd("git", arguments, stderr_to_stdout: true, env: env) do
      {output, 0} ->
        String.trim_trailing(output)

      {output, status} ->
        raise "git #{Enum.join(arguments, " ")} failed with status #{status}:\n#{output}"
    end
  end

  defp commit_env(day) do
    date = "2026-01-0#{day}T03:04:05Z"
    [{"GIT_AUTHOR_DATE", date}, {"GIT_COMMITTER_DATE", date}]
  end

  defp tag_env do
    [
      {"GIT_AUTHOR_DATE", "2026-01-03T03:04:05Z"},
      {"GIT_COMMITTER_DATE", "2026-01-03T03:04:05Z"}
    ]
  end

  defp assert_equal!(actual, expected, _label) when actual == expected, do: :ok

  defp assert_equal!(actual, expected, label) do
    raise "#{label} expected #{inspect(expected)}, got #{inspect(actual)}"
  end

  defp assert_greater_than!(actual, minimum, _label) when actual > minimum, do: :ok

  defp assert_greater_than!(actual, minimum, label) do
    raise "#{label} must be greater than #{minimum}, got #{actual}"
  end

  defp unwrap!({:ok, value}, _action), do: value

  defp unwrap!({:error, reason}, action) do
    raise "#{action} failed: #{inspect(reason)}"
  end

  defp unwrap_transaction!({:ok, value}, _action), do: value

  defp unwrap_transaction!({:error, reason}, action) do
    raise "#{action} failed: #{inspect(reason)}"
  end
end

Fornacast.RepositoryQAFixture.run(System.argv())
