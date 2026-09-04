defmodule ForgeImports.GitHub.MetadataImporterTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeAccounts
  alias ForgeImports.GitHub.{Client, MetadataImporter}
  alias ForgeImports.{ObjectMapping, PageCheckpoint, Persistence, ReportEntry, RepositoryItem}
  alias ForgeIssues.{Comment, Issue, IssueAssignee, Label, NumberSequence}
  alias ForgePulls.PullRequest
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @fixtures Path.expand("../fixtures/github", __DIR__)
  @now ~U[2026-08-28 01:00:00Z]
  @pat "github_pat_metadata_importer_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<11>>, 32)}}
  @terminal_resources ~w(labels issues comments pull_requests number_sequence)

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture("metadata-importer")
    identity = identity_fixture(actor)
    run = running_run_fixture(actor, identity)
    %{actor: actor, identity: identity, run: run}
  end

  test "imports labels, issues, comments, assignees, and a same-repo pull with terminal checkpoints",
       %{run: run} do
    {item, repository, _stub, head_sha, base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    issue_payload =
      fixture!("issues_page.json")
      |> hd()
      |> Map.put("number", 3)
      |> Map.put("assignees", [
        %{
          "id" => 9001,
          "login" => "hubot",
          "avatar_url" => "https://avatars.githubusercontent.com/u/9001",
          "html_url" => "https://github.com/hubot"
        }
      ])
      |> Map.put("labels", fixture!("labels_page.json"))

    pull_issue =
      fixture!("issues_page.json")
      |> hd()
      |> Map.put("number", 7)
      |> Map.put("pull_request", %{
        "url" => "https://api.github.com/repos/octocat/Hello-World/pulls/7"
      })

    ghost_comment =
      fixture!("comments_page.json")
      |> hd()
      |> Map.put("id", 603)
      |> Map.put("body", "Ghost comment")
      |> Map.put("user", nil)

    comment_issue_3 =
      fixture!("comments_page.json")
      |> hd()
      |> Map.put("id", 602)
      |> Map.put("body", "Issue 3 comment")

    stub =
      stub_client!(
        labels: fixture!("labels_page.json"),
        issues: [issue_payload, pull_issue],
        comments: %{
          3 => [comment_issue_3, ghost_comment]
        },
        pull: align_pull_payload(fixture!("pull_same_repo.json"), head_sha, base_sha)
      )

    assert :ok = stage(item, stub)

    assert terminal?(item.id, "labels")
    assert terminal?(item.id, "issues")
    assert terminal?(item.id, "comments")
    assert terminal?(item.id, "pull_requests")
    assert terminal?(item.id, "number_sequence")

    assert [%Label{name: "bug"}] =
             Repo.all(from(label in Label, where: label.repository_id == ^repository.id))

    assert %Issue{number: 3, author_github_identity_id: author_id, title: "Issue title"} =
             Repo.get_by!(Issue, repository_id: repository.id, number: 3)

    assert author_id
    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 3)
    assert Repo.get_by!(IssueAssignee, issue_id: issue.id)

    assert %Comment{body: "Issue 3 comment", author_github_identity_id: comment_author_id} =
             Repo.get_by!(Comment, issue_id: issue.id, body: "Issue 3 comment")

    assert comment_author_id

    ghost = ForgeAccounts.github_deleted_identity()

    assert Repo.exists?(
             from(comment in Comment,
               join: issue in Issue,
               on: issue.id == comment.issue_id,
               where: issue.number == ^3 and comment.author_github_identity_id == ^ghost.id
             )
           )

    assert %Issue{number: 7, kind: :pull_request} =
             Repo.get_by!(Issue, repository_id: repository.id, number: 7)

    assert Repo.get_by!(PullRequest, repository_id: repository.id)

    assert Repo.exists?(
             from mapping in ObjectMapping,
               where:
                 mapping.repository_item_id == ^item.id and mapping.object_kind == "pull_request"
           )

    assert Repo.exists?(
             from sequence in NumberSequence, where: sequence.repository_id == ^repository.id
           )

    refute ForgeRepos.get_repository(user_slug(run), item.destination_slug)
  end

  test "skips cross-repository and draft pulls without creating issue rows", %{run: run} do
    {item, repository, stub, _head_sha, _base_sha} =
      git_staged_fixture(run,
        full_name: "octocat/Hello-World",
        github_repository_id: 1_296_269
      )

    cross = fixture!("pull_cross_repo.json")
    draft = cross |> Map.put("draft", true) |> Map.put("number", 9) |> Map.put("id", 703)

    stub =
      stub_client!(stub,
        labels: [],
        issues: [],
        comments: %{},
        pulls: [cross, draft]
      )

    for number <- [cross["number"], draft["number"]] do
      %ReportEntry{}
      |> ReportEntry.create_changeset(%{
        import_run_id: run.id,
        repository_item_id: item.id,
        idempotency_key: "pull-candidate-#{item.id}-#{number}",
        scope: :object,
        object_kind: "pull_request",
        source_object_id: number,
        outcome: :skipped,
        classification: "pull_candidate",
        summary: "Pull request deferred to pull phase",
        metadata: %{"count" => number},
        source_count: 0
      })
      |> Repo.insert!()
    end

    assert :ok = stage(item, stub, phases: [:pull_requests])

    refute Repo.exists?(from issue in Issue, where: issue.repository_id == ^repository.id)

    assert Repo.aggregate(
             from(report in ReportEntry,
               where:
                 report.repository_item_id == ^item.id and
                   report.classification != "pull_candidate"
             ),
             :count
           ) >= 2
  end

  test "replaying committed pages is a no-op", %{run: run} do
    {item, repository, stub, _head_sha, _base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    issue =
      fixture!("issues_page.json")
      |> hd()
      |> Map.put("number", 11)

    stub =
      stub_client!(stub,
        labels: fixture!("labels_page.json"),
        issues: [issue],
        comments: %{11 => fixture!("comments_page.json")},
        pull: nil
      )

    assert :ok = stage(item, stub)

    label_count =
      Repo.aggregate(from(l in Label, where: l.repository_id == ^repository.id), :count)

    issue_count =
      Repo.aggregate(from(i in Issue, where: i.repository_id == ^repository.id), :count)

    checkpoint_count =
      Repo.aggregate(from(c in PageCheckpoint, where: c.repository_item_id == ^item.id), :count)

    assert :ok = stage(item, stub)

    assert label_count ==
             Repo.aggregate(from(l in Label, where: l.repository_id == ^repository.id), :count)

    assert issue_count ==
             Repo.aggregate(from(i in Issue, where: i.repository_id == ^repository.id), :count)

    assert checkpoint_count ==
             Repo.aggregate(
               from(c in PageCheckpoint, where: c.repository_item_id == ^item.id),
               :count
             )
  end

  test "client failures do not commit resource checkpoints", %{run: run} do
    {item, repository, _stub, _head_sha, _base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    broken = stub_name()

    Req.Test.stub(broken, fn conn ->
      Plug.Conn.send_resp(conn, 500, ~s({"message":"broken"}))
    end)

    assert {:error, _} = MetadataImporter.stage_phase(item, :labels, importer_opts(broken, item))
    refute terminal?(item.id, "labels")
    refute Repo.exists?(from(label in Label, where: label.repository_id == ^repository.id))
  end

  test "number_sequence runs only after every resource phase is terminal", %{run: run} do
    {item, repository, stub, _head_sha, _base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    issue =
      fixture!("issues_page.json")
      |> hd()
      |> Map.put("number", 5)

    stub =
      stub_client!(stub,
        labels: [],
        issues: [issue],
        comments: %{5 => []},
        pull: nil
      )

    for phase <- [:labels, :issues, :comments, :pull_requests] do
      refute terminal?(item.id, Atom.to_string(phase))
      assert :ok = MetadataImporter.stage_phase(item, phase, importer_opts(stub, item))
      assert terminal?(item.id, Atom.to_string(phase))
    end

    refute Repo.exists?(
             from sequence in NumberSequence, where: sequence.repository_id == ^repository.id
           )

    assert :ok = MetadataImporter.stage_phase(item, :number_sequence, importer_opts(stub, item))
    assert terminal?(item.id, "number_sequence")

    assert Repo.exists?(
             from sequence in NumberSequence, where: sequence.repository_id == ^repository.id
           )
  end

  defp stage(item, stub, opts \\ []) do
    phases = Keyword.get(opts, :phases, @terminal_resources |> Enum.map(&String.to_atom/1))
    importer_opts = importer_opts(stub, item)

    Enum.reduce_while(phases, :ok, fn phase, :ok ->
      result =
        case phase do
          "number_sequence" ->
            MetadataImporter.stage_phase(item, :number_sequence, importer_opts)

          phase when is_binary(phase) ->
            MetadataImporter.stage_phase(item, String.to_atom(phase), importer_opts)

          phase when is_atom(phase) ->
            MetadataImporter.stage_phase(item, phase, importer_opts)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
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
                 source_git: %{"empty" => false, "default_branch" => "main", "refs" => 2},
                 checkpoint: %{"git_staged" => true, "unsupported_scan" => "complete"}
               ]
             )

    shadow = Repo.get!(Repository, shadow.id)
    item = Repo.get!(RepositoryItem, item.id)
    stub = stub_name()
    {item, shadow, stub, head_sha, base_sha}
  end

  defp align_pull_payload(payload, head_sha, base_sha) do
    payload
    |> put_in(["head", "sha"], head_sha)
    |> put_in(["base", "sha"], base_sha)
  end

  defp stub_client!(stub, responses) do
    parent = self()
    labels = Keyword.fetch!(responses, :labels)
    issues = Keyword.fetch!(responses, :issues)
    comments = Keyword.fetch!(responses, :comments)
    pull = Keyword.get(responses, :pull)
    pulls = Keyword.get(responses, :pulls, if(pull, do: [pull], else: []))

    Req.Test.stub(stub, fn conn ->
      send(parent, {:request, conn.request_path, conn.query_string})

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

  defp importer_opts(stub, item) do
    [
      credential_checkout: fn callback -> callback.(@pat) end,
      gate_key: {:one_time_run, item.import_run_id},
      client_options: client_opts(stub)
    ]
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
    base = git!(path, git_identity_args() ++ ["commit-tree", tree, "-m", "base"])
    head = git!(path, git_identity_args() ++ ["commit-tree", tree, "-p", base, "-m", "head"])
    update_ref!(path, head, "refs/heads/feature")
    update_ref!(path, base, "refs/heads/main")
    {head, base}
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["--git-dir=#{path}" | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp git_identity_args,
    do: ["-c", "user.name=Fornacast Import", "-c", "user.email=import@example.test"]

  defp update_ref!(path, oid, ref) do
    {_, 0} =
      System.cmd("git", ["--git-dir=#{path}", "update-ref", ref, oid], stderr_to_stdout: true)
  end

  defp terminal?(item_id, resource) do
    Repo.exists?(
      from checkpoint in PageCheckpoint,
        where:
          checkpoint.repository_item_id == ^item_id and checkpoint.resource_kind == ^resource and
            checkpoint.page_key == "__terminal_v1__"
    )
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

  defp user_slug(%{actor_user_id: actor_id}) do
    Repo.get!(ForgeAccounts.User, actor_id).username
  end

  defp user_slug(run), do: user_slug(%{actor_user_id: run.actor_user_id})

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
