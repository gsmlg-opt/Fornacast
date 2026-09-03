defmodule ForgeImports.GitHubMetadataImportIntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeImports.GitHub.MetadataImporter
  alias ForgeImports.{ImportAttempt, Persistence, ReportEntry, RepositoryItem}
  alias ForgeIssues.{Issue, NumberSequence}
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @fixtures Path.expand("github", Path.join(__DIR__, "fixtures"))
  @now ~U[2026-08-28 02:00:00Z]
  @pat "github_pat_metadata_integration_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<13>>, 32)}}

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture("metadata-integration")
    identity = identity_fixture(actor)
    run = running_run_fixture(actor, identity)
    %{actor: actor, identity: identity, run: run}
  end

  test "publishes imported metadata and allocates ordinary numbers afterward", %{
    actor: actor,
    run: run
  } do
    {item, shadow, stub, head_sha, base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    issue_payload =
      fixture!("issues_page.json")
      |> hd()
      |> Map.put("number", 3)

    pull_issue =
      fixture!("issues_page.json")
      |> hd()
      |> Map.put("number", 7)
      |> Map.put("pull_request", %{
        "url" => "https://api.github.com/repos/octocat/Hello-World/pulls/7"
      })

    cross = fixture!("pull_cross_repo.json")

    stub =
      stub_client!(stub,
        labels: fixture!("labels_page.json"),
        issues: [issue_payload, pull_issue],
        comments: %{3 => fixture!("comments_page.json")},
        pulls: [align_pull_payload(fixture!("pull_same_repo.json"), head_sha, base_sha), cross]
      )

    assert :ok = MetadataImporter.stage(item, credential_checkout(), importer_opts(stub, item))

    assert Repo.exists?(
             from report in ReportEntry,
               where:
                 report.repository_item_id == ^item.id and
                   report.classification == "pull_candidate" and report.source_object_id == ^7
           )

    ready_item = mark_ready_to_publish!(item)
    attempt_fixture(ready_item)

    assert {:ok, %{repository: published, replaced: nil}} =
             ForgeImports.publish_repository(actor, ready_item.id, %{
               "request_id" => "metadata-integration-publish",
               "user_agent" => "metadata-integration-test",
               "ip_address" => "127.0.0.1"
             })

    assert published.id == shadow.id
    assert Repo.get!(RepositoryItem, ready_item.id).state in [:published, :completed, :publishing]

    published_repo = ForgeRepos.get_repository(actor.username, ready_item.destination_slug)
    assert published_repo.id == shadow.id

    assert %Issue{number: 3, inserted_at: ~U[2025-01-01 00:00:00Z]} =
             Repo.get_by!(Issue, repository_id: shadow.id, number: 3)

    assert %Issue{number: 7, kind: :pull_request} =
             Repo.get_by!(Issue, repository_id: shadow.id, number: 7)

    refute Repo.exists?(
             from issue in Issue,
               where: issue.repository_id == ^shadow.id and issue.number == ^cross["number"]
           )

    assert %NumberSequence{next_number: 8} = Repo.get!(NumberSequence, shadow.id)

    assert {:ok, %{issue: ordinary}} =
             Multi.new()
             |> ForgeIssues.insert_numbered_identity(
               :issue,
               published_repo,
               actor,
               :issue,
               %{title: "Ordinary follow-up", body: nil}
             )
             |> ForgeIssues.transaction()

    assert ordinary.number == 8
    assert ordinary.author_user_id == actor.id
  end

  defp mark_ready_to_publish!(item) do
    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [state: :ready_to_publish]
             )

    Repo.get!(RepositoryItem, item.id)
  end

  defp attempt_fixture(item) do
    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: %{"action" => "create", "slug" => item.destination_slug},
      started_at: @now
    })
    |> Repo.insert!()
  end

  defp credential_checkout do
    fn callback -> callback.(@pat) end
  end

  defp importer_opts(stub, item) do
    [
      credential_checkout: credential_checkout(),
      gate_key: {:one_time_run, item.import_run_id},
      client_options: client_opts(stub)
    ]
  end

  defp git_staged_fixture(run, opts) do
    github_repository_id = Keyword.get(opts, :github_repository_id, 1_296_269)
    full_name = Keyword.fetch!(opts, :full_name)
    [_owner, name] = String.split(full_name, "/", parts: 2)
    slug = String.downcase(name)

    item =
      %{
        import_run_id: run.id,
        github_repository_id: github_repository_id,
        source_full_name: full_name,
        source_name: name,
        source_metadata: %{
          "default_branch" => "main",
          "visibility" => "private",
          "description" => nil,
          "has_issues" => true,
          "allow_merge_commit" => true,
          "fork" => false,
          "archived" => false
        },
        source_observed_at: @now,
        selected: true,
        destination_owner_id: run.actor_user_id,
        destination_slug: slug,
        destination_visibility: :private,
        state: :queued,
        attempt_count: 1
      }
      |> Persistence.insert_repository_item()
      |> unwrap!()

    {:ok, %{shadow: shadow}} =
      Multi.new()
      |> ForgeRepos.create_import_shadow(:shadow, run.actor_user_id, %{
        item_id: item.id,
        generation: 1
      })
      |> Repo.transaction()

    staged_path = staged_repo_path!(shadow)
    {head_sha, base_sha} = seed_refs!(staged_path)

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [
                 state: :git_staged,
                 hidden_repository_id: shadow.id,
                 staged_storage_path: staged_path,
                 source_git: %{
                   "empty" => false,
                   "default_branch" => "main",
                   "refs" => 2,
                   "bytes" => 512,
                   "lfs_detected" => false,
                   "submodules_detected" => false,
                   "scan_truncated" => false
                 },
                 checkpoint: %{"git_staged" => true, "unsupported_scan" => "complete"}
               ]
             )

    item = Repo.get!(RepositoryItem, item.id)
    stub = stub_name()
    {item, shadow, stub, head_sha, base_sha}
  end

  defp stub_client!(stub, responses) do
    parent = self()
    labels = Keyword.fetch!(responses, :labels)
    issues = Keyword.fetch!(responses, :issues)
    comments = Keyword.fetch!(responses, :comments)
    pulls = Keyword.fetch!(responses, :pulls)

    Req.Test.stub(stub, fn conn ->
      send(parent, {:request, conn.request_path})

      cond do
        String.ends_with?(conn.request_path, "/labels") ->
          Req.Test.json(conn, labels)

        String.ends_with?(conn.request_path, "/issues") and
            not String.contains?(conn.request_path, "/issues/") ->
          Req.Test.json(conn, issues)

        String.contains?(conn.request_path, "/issues/") and
            String.ends_with?(conn.request_path, "/comments") ->
          number = conn.request_path |> String.split("/") |> Enum.at(5) |> String.to_integer()
          Req.Test.json(conn, Map.get(comments, number, []))

        String.contains?(conn.request_path, "/pulls/") ->
          number = conn.request_path |> String.split("/") |> List.last() |> String.to_integer()
          payload = Enum.find(pulls, &(&1["number"] == number))
          if payload, do: Req.Test.json(conn, payload), else: Plug.Conn.send_resp(conn, 404, "{}")

        true ->
          Plug.Conn.send_resp(conn, 404, "{}")
      end
    end)

    stub
  end

  defp stub_client!(responses), do: stub_client!(stub_name(), responses)

  defp align_pull_payload(payload, head_sha, base_sha) do
    payload
    |> put_in(["head", "sha"], head_sha)
    |> put_in(["base", "sha"], base_sha)
  end

  defp client_opts(stub) do
    [
      plug: {Req.Test, stub},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    ]
  end

  defp staged_repo_path!(shadow) do
    path = ForgeRepos.absolute_storage_path(shadow)
    File.mkdir_p!(Path.dirname(path))
    assert {:ok, ^path} = GitCore.init_bare(path)
    path
  end

  defp seed_refs!(path) do
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    base = git!(path, ["commit-tree", tree, "-m", "base"])
    head = git!(path, ["commit-tree", tree, "-p", base, "-m", "head"])
    update_ref!(path, head, "refs/heads/feature")
    update_ref!(path, base, "refs/heads/main")
    {head, base}
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["--git-dir=#{path}" | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp update_ref!(path, oid, ref) do
    {_, 0} =
      System.cmd("git", ["--git-dir=#{path}", "update-ref", ref, oid], stderr_to_stdout: true)
  end

  defp running_run_fixture(actor, identity) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :repository,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 8_950_000_001,
        source_owner_login: "octocat",
        source_repository_github_id: 1_296_269,
        source_repository_full_name: "octocat/Hello-World",
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: :running,
        selected_count: 1,
        request_metadata: %{}
      }
      |> Persistence.insert_run()
      |> unwrap!()

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
        run.id,
        actor.id,
        identity.github_user_id,
        @pat,
        @keyring
      )

    ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring) |> unwrap!()
    run
  end

  defp user_fixture(prefix) do
    suffix = System.unique_integer([:positive])

    %ForgeAccounts.User{}
    |> ForgeAccounts.User.registration_changeset(%{
      username: "#{prefix}-#{suffix}",
      email: "#{prefix}-#{suffix}@example.com",
      password: "correct horse battery staple"
    })
    |> Repo.insert!()
  end

  defp identity_fixture(actor) do
    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 9_000_000_000 + System.unique_integer([:positive]),
          login: actor.username,
          avatar_url: nil,
          profile_url: nil
        },
        @now
      )

    identity
  end

  defp fixture!(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp stub_name, do: {__MODULE__, System.unique_integer([:positive])}
  defp unwrap!({:ok, value}), do: value

  defp reset_database! do
    for table <- [
          "github_import_report_entries",
          "github_import_page_checkpoints",
          "github_import_object_mappings",
          "github_import_attempts",
          "github_import_repository_items",
          "github_import_runs",
          "issue_comments",
          "issue_assignees",
          "issue_labels",
          "issues",
          "labels",
          "number_sequences",
          "pull_requests",
          "github_identities",
          "repositories",
          "users"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
    end
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
