defmodule ForgeImports.GitHub.MetadataImporterTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeAccounts
  alias ForgeImports.GitHub.MetadataImporter

  alias ForgeImports.{
    ImportRun,
    ObjectMapping,
    PageCheckpoint,
    Persistence,
    ReportEntry,
    RepositoryItem
  }

  alias ForgeIssues.{Comment, Issue, IssueAssignee, Label, NumberSequence}
  alias ForgePulls.PullRequest
  alias ForgeReleases.Release
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @fixtures Path.expand("../fixtures/github", __DIR__)
  @now ~U[2026-08-28 01:00:00Z]
  @pat "github_pat_metadata_importer_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<11>>, 32)}}
  @terminal_resources ~w(labels issues comments pull_requests releases number_sequence)

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
      |> Map.put("id", 302)
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

    assert %PullRequest{id: pull_id} = Repo.get_by!(PullRequest, repository_id: repository.id)
    pull_issue_row = Repo.get_by!(Issue, repository_id: repository.id, number: 7)

    assert %ObjectMapping{github_object_id: 302} =
             Repo.get_by!(ObjectMapping,
               repository_item_id: item.id,
               object_kind: "issue",
               local_resource_id: pull_issue_row.id
             )

    assert %ObjectMapping{local_resource_id: ^pull_id} =
             Repo.get_by!(ObjectMapping,
               repository_item_id: item.id,
               object_kind: "pull_request"
             )

    assert Repo.exists?(
             from sequence in NumberSequence, where: sequence.repository_id == ^repository.id
           )

    refute ForgeRepos.get_repository(user_slug(run), item.destination_slug)
  end

  test "legacy candidate and completed mappings require authenticated issue identity revalidation",
       %{run: run} do
    {item, repository, _, head_sha, base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    issue =
      hd(fixture!("issues_page.json"))
      |> Map.put("pull_request", %{
        "url" => "https://api.github.com/repos/octocat/Hello-World/pulls/7"
      })

    stub =
      stub_client!(
        labels: [],
        issues: [issue],
        comments: %{},
        pull: align_pull_payload(fixture!("pull_same_repo.json"), head_sha, base_sha)
      )

    assert :ok = stage(item, stub, phases: [:issues])

    candidate =
      Repo.get_by!(ReportEntry, repository_item_id: item.id, classification: "pull_candidate")

    assert candidate.metadata["github_id"] == issue["id"]
    candidate |> Ecto.Changeset.change(metadata: %{"count" => 7}) |> Repo.update!()

    assert {:error, :pull_issue_identity_requires_refetch} =
             stage(item, stub, phases: [:pull_requests])

    refute Repo.exists?(from p in PullRequest, where: p.repository_id == ^repository.id)

    Repo.get!(ReportEntry, candidate.id)
    |> Ecto.Changeset.change(metadata: candidate.metadata)
    |> Repo.update!()

    assert :ok = stage(item, stub, phases: [:pull_requests])

    mappings =
      Repo.all(from m in ObjectMapping, where: m.repository_item_id == ^item.id, order_by: m.id)

    Repo.get!(ReportEntry, candidate.id)
    |> Ecto.Changeset.change(metadata: %{"count" => 7})
    |> Repo.update!()

    assert {:error, :pull_issue_identity_requires_refetch} =
             stage(item, stub, phases: [:pull_requests])

    assert Repo.all(
             from m in ObjectMapping, where: m.repository_item_id == ^item.id, order_by: m.id
           ) == mappings

    assert Repo.exists?(
             from r in ReportEntry,
               where:
                 r.repository_item_id == ^item.id and
                   r.classification == "pull_issue_identity_requires_refetch"
           )
  end

  test "authenticated legacy identity recovery is atomic and idempotent", %{run: run} do
    {item, _, _, head, base} = git_staged_fixture(run, full_name: "octocat/Hello-World")

    issue =
      hd(fixture!("issues_page.json"))
      |> Map.put("pull_request", %{
        "url" => "https://api.github.com/repos/octocat/Hello-World/pulls/7"
      })

    pull = align_pull_payload(fixture!("pull_same_repo.json"), head, base)
    stub = stub_client!(labels: [], issues: [issue], comments: %{}, pull: pull)
    assert :ok = stage(item, stub, phases: [:issues, :pull_requests])

    candidate =
      Repo.get_by!(ReportEntry, repository_item_id: item.id, classification: "pull_candidate")

    candidate |> Ecto.Changeset.change(metadata: %{"count" => 7}) |> Repo.update!()
    mapping = Repo.get_by!(ObjectMapping, repository_item_id: item.id, object_kind: "issue")
    mapping |> Ecto.Changeset.change(github_object_id: pull["id"]) |> Repo.update!()

    assert {:error, :pull_issue_identity_requires_refetch} =
             stage(item, stub, phases: [:pull_requests])

    for response <- [:denied, :wrong_repository, :wrong_pull, :wrong_signpost] do
      recovery_stub!(stub, item, issue, pull, response)

      assert {:error, _} =
               MetadataImporter.revalidate_pull_issue_identity(item, 7, importer_opts(stub, item))

      assert Repo.get!(ObjectMapping, mapping.id).github_object_id == pull["id"]
      assert Repo.get!(ReportEntry, candidate.id).metadata == %{"count" => 7}
    end

    recovery_stub!(stub, item, issue, pull, :ok)

    Repo.get!(ReportEntry, candidate.id)
    |> Ecto.Changeset.change(metadata: %{"count" => 7, "github_id" => 999})
    |> Repo.update!()

    assert {:error, :pull_issue_identity_mismatch} =
             MetadataImporter.revalidate_pull_issue_identity(item, 7, importer_opts(stub, item))

    assert Repo.get!(ObjectMapping, mapping.id).github_object_id == pull["id"]

    Repo.get!(ReportEntry, candidate.id)
    |> Ecto.Changeset.change(metadata: %{"count" => 7})
    |> Repo.update!()

    other_owner = user_fixture("identity-recovery-other-owner")
    hidden = Repo.get!(ForgeRepos.Repository, item.hidden_repository_id)
    hidden |> Ecto.Changeset.change(owner_user_id: other_owner.id) |> Repo.update!()

    assert {:error, :stale_item} =
             MetadataImporter.revalidate_pull_issue_identity(item, 7, importer_opts(stub, item))

    assert Repo.get!(ObjectMapping, mapping.id).github_object_id == pull["id"]

    Repo.get!(ForgeRepos.Repository, hidden.id)
    |> Ecto.Changeset.change(owner_user_id: hidden.owner_user_id)
    |> Repo.update!()

    current_run = Repo.get!(ForgeImports.ImportRun, run.id)

    current_run
    |> Ecto.Changeset.change(
      credential_source: :github_app,
      github_identity_id: nil,
      credential_ciphertext: nil,
      credential_nonce: nil,
      credential_tag: nil,
      credential_key_id: nil
    )
    |> Repo.update!()

    assert {:error, _} =
             MetadataImporter.revalidate_pull_issue_identity(item, 7, importer_opts(stub, item))

    assert Repo.get!(ObjectMapping, mapping.id).github_object_id == pull["id"]

    Repo.get!(ForgeImports.ImportRun, run.id)
    |> Ecto.Changeset.change(
      credential_source: current_run.credential_source,
      github_identity_id: current_run.github_identity_id,
      credential_ciphertext: current_run.credential_ciphertext,
      credential_nonce: current_run.credential_nonce,
      credential_tag: current_run.credential_tag,
      credential_key_id: current_run.credential_key_id
    )
    |> Repo.update!()

    Repo.get!(ForgeImports.ImportRun, run.id)
    |> Ecto.Changeset.change(state: :cancel_requested)
    |> Repo.update!()

    assert {:error, :stale_item} =
             MetadataImporter.revalidate_pull_issue_identity(item, 7, importer_opts(stub, item))

    Repo.get!(ForgeImports.ImportRun, run.id)
    |> Ecto.Changeset.change(state: :running)
    |> Repo.update!()

    expired =
      Repo.get!(ForgeImports.RepositoryItem, item.id)
      |> Ecto.Changeset.change(
        lease_owner: "expired-recovery",
        lease_expires_at: ~U[2020-01-01 00:00:00Z]
      )
      |> Repo.update!()

    assert {:error, :stale_item} =
             MetadataImporter.revalidate_pull_issue_identity(
               expired,
               7,
               importer_opts(stub, expired)
             )

    expired |> Ecto.Changeset.change(lease_owner: nil, lease_expires_at: nil) |> Repo.update!()
    assert Repo.get!(ObjectMapping, mapping.id).github_object_id == pull["id"]

    assert :ok =
             MetadataImporter.revalidate_pull_issue_identity(item, 7, importer_opts(stub, item))

    assert Repo.get!(ObjectMapping, mapping.id).github_object_id == issue["id"]
    assert Repo.get!(ReportEntry, candidate.id).metadata["github_id"] == issue["id"]

    assert :ok =
             MetadataImporter.revalidate_pull_issue_identity(item, 7, importer_opts(stub, item))

    assert :ok = stage(item, stub, phases: [:pull_requests])

    report =
      Repo.get_by!(ReportEntry,
        repository_item_id: item.id,
        classification: "pull_issue_identity_requires_refetch"
      )

    assert report.outcome == :imported
    assert report.metadata["code"] == "authenticated_refetch_completed"

    Repo.get!(ReportEntry, candidate.id)
    |> Ecto.Changeset.change(metadata: %{"count" => 7})
    |> Repo.update!()

    second =
      %ReportEntry{}
      |> ReportEntry.create_changeset(%{
        import_run_id: run.id,
        repository_item_id: item.id,
        idempotency_key: "pull-candidate-#{item.id}-8",
        scope: :object,
        object_kind: "pull_request",
        source_object_id: 8,
        outcome: :skipped,
        classification: "pull_candidate",
        summary: "Legacy candidate",
        metadata: %{"count" => 8},
        source_count: 0
      })
      |> Repo.insert!()

    opts = importer_opts(stub, item)

    assert {:ok, :identity_recovered} =
             MetadataImporter.stage(item, Keyword.fetch!(opts, :credential_checkout), opts)

    assert Repo.get!(ReportEntry, candidate.id).metadata["github_id"] == issue["id"]
    assert Repo.get!(ReportEntry, second.id).metadata == %{"count" => 8}

    Repo.get!(ReportEntry, candidate.id)
    |> Ecto.Changeset.change(metadata: %{"count" => 7})
    |> Repo.update!()

    %ForgeImports.ImportAttempt{}
    |> ForgeImports.ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: %{"action" => "create", "slug" => item.destination_slug},
      started_at: DateTime.utc_now(:second)
    })
    |> Repo.insert!()

    assert {:ok,
            %ForgeImports.RepositoryItem{
              state: :staging_metadata,
              lease_owner: nil,
              failure_kind: nil
            }} =
             ForgeImports.RepositoryWorker.stage(item.id,
               owner: "bounded-identity-recovery",
               keyring: @keyring,
               client_options: client_opts(stub)
             )

    assert Repo.get!(ReportEntry, candidate.id).metadata["github_id"] == issue["id"]
    assert Repo.get!(ReportEntry, second.id).metadata == %{"count" => 8}
  end

  defp recovery_stub!(stub, item, issue, pull, response) do
    pull = authenticated_pull_payload(pull)
    issue = authenticated_pull_issue(issue, pull)

    Req.Test.stub(stub, fn conn ->
      cond do
        response == :denied ->
          Plug.Conn.send_resp(conn, 403, "{}")

        String.ends_with?(conn.request_path, "/issues/7") ->
          Req.Test.json(
            conn,
            if(response == :wrong_signpost,
              do:
                Map.put(issue, "pull_request", %{
                  "url" => "https://api.github.com/repos/other/repo/pulls/7"
                }),
              else: issue
            )
          )

        String.ends_with?(conn.request_path, "/pulls/7") ->
          Req.Test.json(
            conn,
            if(response == :wrong_pull, do: Map.put(pull, "id", 999), else: pull)
          )

        true ->
          Req.Test.json(conn, %{
            "id" => if(response == :wrong_repository, do: 999, else: item.github_repository_id),
            "name" => "Hello-World",
            "full_name" => item.source_full_name,
            "default_branch" => "main",
            "visibility" => "public",
            "has_issues" => true,
            "fork" => false,
            "archived" => false,
            "private" => false,
            "owner" => %{"id" => 583_231, "login" => "octocat"}
          })
      end
    end)
  end

  test "imports external heads read-only and preserves same-repository drafts", %{run: run} do
    {item, repository, stub, head_sha, base_sha} =
      git_staged_fixture(run,
        full_name: "octocat/Hello-World",
        github_repository_id: 1_296_269
      )

    cross =
      fixture!("pull_cross_repo.json")
      |> align_pull_payload(head_sha, base_sha)
      |> put_in(["head", "repo", "node_id"], "R_external_head")

    draft =
      fixture!("pull_same_repo.json")
      |> align_pull_payload(head_sha, base_sha)
      |> Map.put("draft", true)
      |> Map.put("number", 9)
      |> Map.put("id", 703)
      |> Map.put("state", "open")
      |> Map.put("merged", false)
      |> Map.put("merged_by", nil)

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
        metadata: %{"count" => number, "github_id" => 300 + number},
        source_count: 0
      })
      |> Repo.insert!()
    end

    conflicting =
      %ReportEntry{}
      |> ReportEntry.create_changeset(%{
        import_run_id: run.id,
        repository_item_id: item.id,
        idempotency_key: "pull-head-identity-#{item.id}-#{cross["id"]}",
        scope: :object,
        object_kind: "pull_request",
        source_object_id: cross["id"],
        outcome: :imported,
        classification: "pull_head_identity",
        summary: "Prior head identity",
        metadata: %{"github_id" => 777, "github_node_id" => "R_other"},
        source_count: 0
      })
      |> Repo.insert!()

    assert {:error, :pull_head_identity_mismatch} = stage(item, stub, phases: [:pull_requests])
    refute Repo.exists?(from i in Issue, where: i.repository_id == ^repository.id)
    Repo.delete!(conflicting)
    assert :ok = stage(item, stub, phases: [:pull_requests])

    external_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 8)
    external = Repo.get_by!(PullRequest, issue_id: external_issue.id)
    assert external.head_repository_id == nil
    assert external.head_sha == head_sha
    draft_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 9)
    draft_pull = Repo.get_by!(PullRequest, issue_id: draft_issue.id)
    assert draft_pull.draft
    assert draft_pull.head_repository_id == repository.id

    evidence =
      Repo.get_by!(ReportEntry,
        repository_item_id: item.id,
        classification: "pull_head_identity",
        source_object_id: cross["id"]
      )

    assert evidence.metadata["github_id"] == cross["head"]["repo"]["id"]
    assert evidence.metadata["github_node_id"] == "R_external_head"
    assert :ok = stage(item, stub, phases: [:pull_requests])
  end

  test "represented bootstrap heads require active confirmed live refs and reject stale absence",
       %{run: run, actor: actor} do
    {item, shadow, _, _, base_sha} = git_staged_fixture(run, full_name: "octocat/Hello-World")

    {:ok, organization} =
      ForgeAccounts.create_organization(actor, %{
        username: "head-binding-#{item.id}",
        display_name: "Head Binding"
      })

    mirror =
      ForgeMirrors.TestSupport.MirrorFixtures.active_organization_mirror_fixture(%{
        organization_id: organization.id,
        github_installation_id: System.system_time(:microsecond),
        bootstrap_import_run_id: run.id,
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    Repo.get!(ForgeImports.ImportRun, run.id)
    |> Ecto.Changeset.change(source_owner_github_id: mirror.github_account_id)
    |> Repo.update!()

    item = item |> Ecto.Changeset.change(destination_owner_id: organization.id) |> Repo.update!()
    shadow |> Ecto.Changeset.change(owner_user_id: organization.id) |> Repo.update!()

    mapped = %{
      github_id: 702,
      head_github_repository_id: 9_999_999,
      head_github_node_id: "R_head",
      head_ref: "refs/heads/feature",
      head_sha: String.duplicate("a", 40)
    }

    assert {:ok, absent} = ForgeImports.GitHub.PullHeadBinding.observe(item, mapped)

    assert {:ok, nil} =
             ForgeImports.GitHub.PullHeadBinding.with_observation(
               item,
               mapped,
               absent,
               &{:ok, &1}
             )

    binding =
      ForgeMirrors.TestSupport.MirrorFixtures.repository_mirror_fixture(
        mirror,
        %{github_repository_id: 9_999_999, github_node_id: "R_head"}
      )

    assert {:error, :pull_head_not_ready} =
             ForgeImports.GitHub.PullHeadBinding.with_observation(
               item,
               mapped,
               absent,
               &{:ok, &1}
             )

    assert {:error, :pull_head_not_ready} =
             ForgeImports.GitHub.PullHeadBinding.observe(item, mapped)

    issue =
      hd(fixture!("issues_page.json"))
      |> Map.put("number", 8)
      |> Map.put("pull_request", %{
        "url" => "https://api.github.com/repos/octocat/Hello-World/pulls/8"
      })

    payload =
      fixture!("pull_cross_repo.json")
      |> put_in(["base", "sha"], base_sha)
      |> put_in(["head", "repo", "node_id"], "R_head")

    stub = stub_client!(labels: [], issues: [issue], comments: %{}, pull: payload)
    assert :ok = stage(item, stub, phases: [:issues])
    assert {:error, :pull_head_not_ready} = stage(item, stub, phases: [:pull_requests])

    assert Repo.exists?(
             from r in ReportEntry,
               where:
                 r.repository_item_id == ^item.id and r.classification == "pull_head_not_ready"
           )

    refute Repo.exists?(from p in PullRequest, where: p.repository_id == ^shadow.id)

    head_repository =
      Repo.get!(Repository, binding.repository_id)
      |> Ecto.Changeset.change(storage_path: "head-binding/#{binding.id}.git")
      |> Repo.update!()

    path = staged_repo_path!(head_repository)
    {head_sha, _} = seed_refs!(path)
    mapped = %{mapped | head_sha: head_sha}

    %ForgeMirrors.MirrorRefState{}
    |> ForgeMirrors.MirrorRefState.persistence_changeset(%{
      repository_mirror_id: binding.id,
      ref_name: mapped.head_ref,
      ref_kind: :branch,
      state: :confirmed,
      confirmed_oid: head_sha,
      last_local_oid: head_sha,
      last_remote_oid: head_sha,
      last_confirmed_at: DateTime.utc_now(:second)
    })
    |> Repo.insert!()

    assert {:ok, proof} = ForgeImports.GitHub.PullHeadBinding.observe(item, mapped)

    assert {:ok, local_id} =
             ForgeImports.GitHub.PullHeadBinding.with_observation(item, mapped, proof, &{:ok, &1})

    assert local_id == head_repository.id

    invalid_payload =
      payload
      |> put_in(["head", "sha"], head_sha)
      |> Map.put("merged_by", %{"id" => 9001, "login" => "hubot"})

    stub_client!(stub, labels: [], issues: [issue], comments: %{}, pull: invalid_payload)
    assert {:error, %Ecto.Changeset{}} = stage(item, stub, phases: [:pull_requests])

    assert Repo.get_by!(ReportEntry,
             repository_item_id: item.id,
             classification: "pull_head_not_ready",
             source_object_id: payload["id"]
           ).outcome == :warning

    refute Repo.exists?(
             from r in ReportEntry,
               where:
                 r.repository_item_id == ^item.id and r.classification == "pull_head_identity"
           )

    stub_client!(stub,
      labels: [],
      issues: [issue],
      comments: %{},
      pull: put_in(payload, ["head", "sha"], head_sha)
    )

    assert :ok = stage(item, stub, phases: [:pull_requests])
    imported_issue = Repo.get_by!(Issue, repository_id: shadow.id, number: 8)

    resolved =
      Repo.get_by!(ReportEntry,
        repository_item_id: item.id,
        classification: "pull_head_not_ready",
        source_object_id: payload["id"]
      )

    assert resolved.outcome == :imported
    assert resolved.metadata["code"] == "head_ref_proof_confirmed"

    assert Repo.get_by!(PullRequest, issue_id: imported_issue.id).head_repository_id ==
             head_repository.id

    binding |> Ecto.Changeset.change(state: :orphaned) |> Repo.update!()

    assert {:error, :pull_head_not_ready} =
             ForgeImports.GitHub.PullHeadBinding.with_observation(item, mapped, proof, &{:ok, &1})

    node_missing = %{mapped | head_github_node_id: nil}

    Repo.get!(ForgeMirrors.RepositoryMirror, binding.id)
    |> Ecto.Changeset.change(state: :active)
    |> Repo.update!()

    assert {:error, :pull_head_not_ready} =
             ForgeImports.GitHub.PullHeadBinding.observe(item, node_missing)

    dangling_lease =
      item
      |> Ecto.Changeset.change(lease_expires_at: DateTime.add(DateTime.utc_now(:second), 60))
      |> Repo.update!()

    assert {:error, :pull_head_not_ready} =
             ForgeImports.GitHub.PullHeadBinding.with_observation(
               dangling_lease,
               mapped,
               proof,
               &{:ok, &1}
             )

    dangling_lease |> Ecto.Changeset.change(lease_expires_at: nil) |> Repo.update!()
    update_ref!(path, git!(path, ["rev-parse", "refs/heads/main"]), mapped.head_ref)

    assert {:error, :pull_head_not_ready} =
             ForgeImports.GitHub.PullHeadBinding.with_observation(item, mapped, proof, &{:ok, &1})

    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    File.write!(Path.join(path, mapped.head_ref), tree <> "\n")

    ref =
      Repo.get_by!(ForgeMirrors.MirrorRefState,
        repository_mirror_id: binding.id,
        ref_name: mapped.head_ref
      )

    ref
    |> Ecto.Changeset.change(confirmed_oid: tree, last_local_oid: tree, last_remote_oid: tree)
    |> Repo.update!()

    mapped = %{mapped | head_sha: tree}
    assert {:ok, tree_proof} = ForgeImports.GitHub.PullHeadBinding.observe(item, mapped)

    assert {:error, :pull_head_not_ready} =
             ForgeImports.GitHub.PullHeadBinding.with_observation(
               item,
               mapped,
               tree_proof,
               &{:ok, &1}
             )
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

    for phase <- [:labels, :issues, :comments, :pull_requests, :releases] do
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

  test "release pages atomically import canonical metadata, mappings, checkpoints, and bounded asset evidence",
       %{run: run} do
    {item, repository, stub, head_sha, _base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    for tag <- ["v1.0.0", "v1.1.0", "v2.0.0"],
        do: update_ref!(item.staged_storage_path, head_sha, "refs/tags/#{tag}")

    first =
      release_payload(41, asset_count: 2, tag_name: "v1.0.0")
      |> Map.put("html_url", "https://github.com/octocat/Hello-World/releases/tag/v1.0.0")

    second = release_payload(42, tag_name: "v1.1.0", draft: true, published_at: nil)
    third = release_payload(43, tag_name: "v2.0.0", prerelease: true)

    stub_client!(stub,
      labels: [],
      issues: [],
      comments: %{},
      releases: [[first, second], [third]]
    )

    assert :ok = MetadataImporter.stage_phase(item, :releases, importer_opts(stub, item))

    assert terminal?(item.id, "releases")

    assert [
             %PageCheckpoint{page_key: "page:1", item_count: 2},
             %PageCheckpoint{page_key: "page:2", item_count: 1},
             %PageCheckpoint{page_key: "__terminal_v1__", item_count: 0}
           ] =
             Repo.all(
               from checkpoint in PageCheckpoint,
                 where:
                   checkpoint.repository_item_id == ^item.id and
                     checkpoint.resource_kind == "releases",
                 order_by: checkpoint.id
             )

    releases =
      Repo.all(
        from release in Release,
          where: release.repository_id == ^repository.id,
          order_by: release.tag_name
      )

    assert Enum.map(releases, & &1.tag_name) == ["v1.0.0", "v1.1.0", "v2.0.0"]
    assert Enum.find(releases, &(&1.tag_name == "v1.1.0")).published_at == nil

    first_author =
      releases
      |> Enum.find(&(&1.tag_name == "v1.0.0"))
      |> then(&Repo.get!(ForgeAccounts.GitHubIdentity, &1.author_github_identity_id))

    assert first_author.github_node_id == "U_41"

    mappings =
      Repo.all(
        from mapping in ObjectMapping,
          where: mapping.repository_item_id == ^item.id and mapping.object_kind == "release",
          order_by: mapping.github_object_id
      )

    assert Enum.map(mappings, & &1.github_object_id) == [41, 42, 43]
    assert Enum.all?(mappings, &(&1.local_resource_type == "ForgeReleases.Release"))

    warning =
      Repo.get_by!(ReportEntry,
        repository_item_id: item.id,
        classification: "unsupported_release_assets",
        source_object_id: 41
      )

    assert warning.outcome == :warning
    assert warning.metadata == %{"category" => "release_assets", "count" => 2, "github_id" => 41}

    assert Repo.aggregate(
             from(report in ReportEntry,
               where:
                 report.repository_item_id == ^item.id and
                   report.classification == "unsupported_release_assets"
             ),
             :count,
             :id
           ) == 1

    unsupported_fields =
      Repo.get_by!(ReportEntry,
        repository_item_id: item.id,
        classification: "unsupported_release_fields",
        source_object_id: 41
      )

    assert unsupported_fields.metadata == %{
             "category" => "release_fields",
             "field" => "html_url,upload_url",
             "github_id" => 41
           }

    assert unsupported_fields.source_count == 2

    assert Repo.aggregate(
             from(report in ReportEntry,
               where:
                 report.repository_item_id == ^item.id and
                   report.classification == "unsupported_release_fields" and
                   report.source_object_id == 41
             ),
             :count,
             :id
           ) == 1

    persisted = inspect({releases, mappings, warning})
    refute persisted =~ "browser_download_url"
    refute persisted =~ "upload_url"
    refute persisted =~ "asset-sentinel"
    refute persisted =~ "https://github.com/octocat/Hello-World/releases/tag/v1.0.0"

    assert :ok = MetadataImporter.stage_phase(item, :releases, importer_opts(stub, item))

    assert Repo.aggregate(from(r in Release, where: r.repository_id == ^repository.id), :count) ==
             3
  end

  test "release restart skips committed pages and retries an uncommitted page as one transaction",
       %{run: run} do
    {item, repository, stub, head_sha, _base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    for tag <- ["v1", "v2"],
        do: update_ref!(item.staged_storage_path, head_sha, "refs/tags/#{tag}")

    first = release_payload(51, tag_name: "v1")
    conflicting = release_payload(52, tag_name: "v1")
    repaired = release_payload(52, tag_name: "v2")
    parent = self()

    Req.Test.stub(stub, fn conn ->
      assert conn.request_path == "/repos/octocat/Hello-World/releases"
      page = URI.decode_query(conn.query_string)["page"]
      send(parent, {:release_page, page})

      case page do
        "1" ->
          conn
          |> Plug.Conn.put_resp_header(
            "link",
            "<https://api.github.com/repos/octocat/Hello-World/releases?page=2&per_page=100>; rel=\"next\""
          )
          |> Req.Test.json([first])

        "2" ->
          Req.Test.json(conn, [conflicting])
      end
    end)

    assert {:error, _reason} =
             MetadataImporter.stage_phase(item, :releases, importer_opts(stub, item))

    assert_receive {:release_page, "1"}
    assert_receive {:release_page, "2"}
    assert Repo.get_by!(Release, repository_id: repository.id, tag_name: "v1")
    refute Repo.get_by(Release, repository_id: repository.id, tag_name: "v2")
    refute Repo.get_by(ForgeAccounts.GitHubIdentity, github_user_id: 90_052)

    assert Repo.get_by!(PageCheckpoint,
             repository_item_id: item.id,
             resource_kind: "releases",
             page_key: "page:1"
           )

    refute Repo.get_by(PageCheckpoint,
             repository_item_id: item.id,
             resource_kind: "releases",
             page_key: "page:2"
           )

    Req.Test.stub(stub, fn conn ->
      assert URI.decode_query(conn.query_string)["page"] == "2"
      send(parent, :release_page_two_retried)
      Req.Test.json(conn, [repaired])
    end)

    assert :ok = MetadataImporter.stage_phase(item, :releases, importer_opts(stub, item))
    assert_receive :release_page_two_retried
    refute_receive {:release_page, "1"}, 25
    assert Repo.get_by!(Release, repository_id: repository.id, tag_name: "v2")
    assert terminal?(item.id, "releases")
  end

  test "release completion checkpoint bypasses staged Git ref reads during final-page recovery",
       %{run: run} do
    {item, repository, stub, _head_sha, _base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    assert {:ok, _checkpoint} =
             %PageCheckpoint{}
             |> PageCheckpoint.create_changeset(%{
               repository_item_id: item.id,
               resource_kind: "releases",
               page_key: "page:1",
               item_count: 0,
               cursor_metadata: %{"cursor" => "complete"},
               committed_at: @now
             })
             |> Repo.insert()

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in Repository, where: candidate.id == ^repository.id),
               set: [storage_path: "missing-release-ref-proof-#{repository.id}"]
             )

    assert :ok = MetadataImporter.stage_phase(item, :releases, importer_opts(stub, item))
    assert terminal?(item.id, "releases")
  end

  test "release page transaction rejects a reassigned repository-item lease", %{run: run} do
    {item, repository, stub, head_sha, _base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    update_ref!(item.staged_storage_path, head_sha, "refs/tags/v81")

    item =
      item
      |> Ecto.Changeset.change(
        state: :staging_metadata,
        lease_owner: "release-page-owner",
        lease_expires_at: DateTime.add(DateTime.utc_now(:second), 60)
      )
      |> Repo.update!()

    parent = self()

    Req.Test.stub(stub, fn conn ->
      send(parent, :release_page_fetched_before_reassignment)

      Repo.update_all(
        from(candidate in RepositoryItem, where: candidate.id == ^item.id),
        set: [lease_owner: "replacement-owner"]
      )

      Req.Test.json(conn, [release_payload(81, tag_name: "v81")])
    end)

    opts =
      stub
      |> importer_opts(item)
      |> Keyword.put(:heartbeat, fn ->
        send(parent, :release_page_heartbeat)
        :ok
      end)

    assert {:error, :lost_lease} = MetadataImporter.stage_phase(item, :releases, opts)
    assert_receive :release_page_heartbeat
    assert_receive :release_page_fetched_before_reassignment
    refute Repo.exists?(from release in Release, where: release.repository_id == ^repository.id)
    refute Repo.get_by(PageCheckpoint, repository_item_id: item.id, resource_kind: "releases")
    refute Repo.get_by(ForgeAccounts.GitHubIdentity, github_user_id: 90_081)
  end

  test "release page transaction rejects cancellation after a fetched page", %{run: run} do
    {item, repository, stub, head_sha, _base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    update_ref!(item.staged_storage_path, head_sha, "refs/tags/v82")

    item =
      item
      |> Ecto.Changeset.change(
        state: :staging_metadata,
        lease_owner: "release-cancel-owner",
        lease_expires_at: DateTime.add(DateTime.utc_now(:second), 60)
      )
      |> Repo.update!()

    Req.Test.stub(stub, fn conn ->
      Repo.update_all(
        from(candidate in ImportRun, where: candidate.id == ^run.id),
        set: [state: :cancel_requested]
      )

      Req.Test.json(conn, [release_payload(82, tag_name: "v82")])
    end)

    opts = Keyword.put(importer_opts(stub, item), :heartbeat, fn -> :ok end)

    assert {:error, :lost_lease} = MetadataImporter.stage_phase(item, :releases, opts)
    refute Repo.exists?(from release in Release, where: release.repository_id == ^repository.id)
    refute Repo.get_by(PageCheckpoint, repository_item_id: item.id, resource_kind: "releases")
    refute Repo.get_by(ForgeAccounts.GitHubIdentity, github_user_id: 90_082)
  end

  test "missing release tag reporting rejects a reassigned repository-item lease", %{run: run} do
    {item, _repository, stub, _head_sha, _base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    item =
      item
      |> Ecto.Changeset.change(
        state: :staging_metadata,
        lease_owner: "release-missing-tag-owner",
        lease_expires_at: DateTime.add(DateTime.utc_now(:second), 60)
      )
      |> Repo.update!()

    Req.Test.stub(stub, fn conn ->
      Repo.update_all(
        from(candidate in RepositoryItem, where: candidate.id == ^item.id),
        set: [lease_owner: "replacement-owner"]
      )

      Req.Test.json(conn, [release_payload(83, tag_name: "missing-v83")])
    end)

    opts = Keyword.put(importer_opts(stub, item), :heartbeat, fn -> :ok end)

    assert {:error, :lost_lease} = MetadataImporter.stage_phase(item, :releases, opts)

    refute Repo.get_by(ReportEntry,
             repository_item_id: item.id,
             source_object_id: 83,
             classification: "release_tag_missing"
           )

    refute Repo.get_by(PageCheckpoint, repository_item_id: item.id, resource_kind: "releases")
  end

  test "release metadata with a missing staged tag records one durable failure and no page writes",
       %{run: run} do
    {item, repository, stub, _head_sha, _base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    stub_client!(stub,
      labels: [],
      issues: [],
      comments: %{},
      releases: [[release_payload(61, tag_name: "missing-tag", asset_count: 1)]]
    )

    assert {:error, :release_tag_missing} =
             MetadataImporter.stage_phase(item, :releases, importer_opts(stub, item))

    assert %ReportEntry{
             outcome: :failed,
             classification: "release_tag_missing",
             metadata: %{
               "code" => "staged_tag_required",
               "github_id" => 61,
               "phase" => "releases"
             }
           } =
             Repo.get_by!(ReportEntry,
               repository_item_id: item.id,
               source_object_id: 61,
               classification: "release_tag_missing"
             )

    refute Repo.exists?(from release in Release, where: release.repository_id == ^repository.id)

    refute Repo.exists?(
             from mapping in ObjectMapping,
               where: mapping.repository_item_id == ^item.id and mapping.object_kind == "release"
           )

    refute Repo.exists?(
             from checkpoint in PageCheckpoint,
               where:
                 checkpoint.repository_item_id == ^item.id and
                   checkpoint.resource_kind == "releases"
           )

    assert {:error, :release_tag_missing} =
             MetadataImporter.stage_phase(item, :releases, importer_opts(stub, item))

    assert Repo.aggregate(
             from(report in ReportEntry,
               where:
                 report.repository_item_id == ^item.id and
                   report.classification == "release_tag_missing"
             ),
             :count,
             :id
           ) == 1
  end

  test "release pagination skips an immutable id repeated by provider page drift and commits the page",
       %{run: run} do
    {item, repository, stub, head_sha, _base_sha} =
      git_staged_fixture(run, full_name: "octocat/Hello-World")

    update_ref!(item.staged_storage_path, head_sha, "refs/tags/v1")
    first = release_payload(71, tag_name: "v1")
    repeated = release_payload(71, tag_name: "provider-drifted-tag")
    parent = self()

    Req.Test.stub(stub, fn conn ->
      page = URI.decode_query(conn.query_string)["page"]
      send(parent, {:duplicate_release_page, page})

      case page do
        "1" ->
          conn
          |> Plug.Conn.put_resp_header(
            "link",
            "<https://api.github.com/repos/octocat/Hello-World/releases?page=2&per_page=100>; rel=\"next\""
          )
          |> Req.Test.json([first])

        "2" ->
          Req.Test.json(conn, [repeated])
      end
    end)

    assert :ok = MetadataImporter.stage_phase(item, :releases, importer_opts(stub, item))
    assert_receive {:duplicate_release_page, "1"}
    assert_receive {:duplicate_release_page, "2"}

    assert [%Release{tag_name: "v1"}] =
             Repo.all(from release in Release, where: release.repository_id == ^repository.id)

    assert %PageCheckpoint{item_count: 1} =
             Repo.get_by!(PageCheckpoint,
               repository_item_id: item.id,
               resource_kind: "releases",
               page_key: "page:2"
             )

    assert terminal?(item.id, "releases")

    refute Repo.get_by(ReportEntry,
             repository_item_id: item.id,
             source_object_id: 71,
             classification: "release_tag_missing"
           )

    assert Repo.aggregate(
             from(report in ReportEntry,
               where:
                 report.repository_item_id == ^item.id and
                   report.source_object_id == 71 and
                   report.classification == "unsupported_release_fields"
             ),
             :count,
             :id
           ) == 1
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
    release_pages = Keyword.get(responses, :releases, [[]])

    pulls =
      responses
      |> Keyword.get(:pulls, if(pull, do: [pull], else: []))
      |> Enum.map(&authenticated_pull_payload/1)

    issues =
      Enum.map(issues, fn issue ->
        case Enum.find(pulls, &(&1["number"] == issue["number"])) do
          nil -> issue
          pull -> authenticated_pull_issue(issue, pull)
        end
      end)

    Req.Test.stub(stub, fn conn ->
      send(parent, {:request, conn.request_path, conn.query_string})

      cond do
        String.ends_with?(conn.request_path, "/releases") ->
          page =
            conn.query_string |> URI.decode_query() |> Map.fetch!("page") |> String.to_integer()

          payloads = Enum.at(release_pages, page - 1, [])

          conn =
            if page < length(release_pages) do
              Plug.Conn.put_resp_header(
                conn,
                "link",
                "<https://api.github.com/repos/octocat/Hello-World/releases?page=#{page + 1}&per_page=100>; rel=\"next\""
              )
            else
              conn
            end

          Req.Test.json(conn, payloads)

        String.ends_with?(conn.request_path, "/labels") ->
          Req.Test.json(conn, labels)

        String.ends_with?(conn.request_path, "/issues") and
            not String.contains?(conn.request_path, "/issues/") ->
          Req.Test.json(conn, issues)

        String.contains?(conn.request_path, "/issues/") and
            String.ends_with?(conn.request_path, "/comments") ->
          number = conn.request_path |> String.split("/") |> Enum.at(5) |> String.to_integer()
          Req.Test.json(conn, Map.get(comments, number, []))

        String.contains?(conn.request_path, "/issues/") ->
          number = conn.request_path |> String.split("/") |> List.last() |> String.to_integer()
          pull = Enum.find(pulls, &(&1["number"] == number))

          payload =
            Enum.find(issues, &(&1["number"] == number)) ||
              authenticated_pull_issue(%{"id" => 300 + number}, pull)

          if payload, do: Req.Test.json(conn, payload), else: Plug.Conn.send_resp(conn, 404, "{}")

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

  defp authenticated_pull_payload(%{} = pull) do
    head_id = pull["head"]["repo"]["id"]
    base_id = pull["base"]["repo"]["id"]

    pull
    |> Map.put_new("node_id", "PR_#{pull["id"]}")
    |> put_in(
      ["head", "repo"],
      authenticated_repository(pull["head"]["repo"], head_id == base_id)
    )
    |> put_in(["base", "repo"], authenticated_repository(pull["base"]["repo"], true))
  end

  defp release_payload(id, overrides) do
    overrides = Map.new(overrides)
    asset_count = Map.get(overrides, :asset_count, 0)

    %{
      "id" => id,
      "node_id" => "RE_#{id}",
      "url" => "https://api.github.com/repos/octocat/Hello-World/releases/#{id}",
      "upload_url" => "https://uploads.github.com/asset-sentinel{?name}",
      "tag_name" => Map.get(overrides, :tag_name, "v#{id}"),
      "name" => Map.get(overrides, :name, "Release #{id}"),
      "body" => Map.get(overrides, :body, "Release notes #{id}"),
      "draft" => Map.get(overrides, :draft, false),
      "prerelease" => Map.get(overrides, :prerelease, false),
      "target_commitish" => Map.get(overrides, :target_commitish, "main"),
      "published_at" => Map.get(overrides, :published_at, "2026-08-27T01:00:00Z"),
      "created_at" => "2026-08-26T01:00:00Z",
      "updated_at" => "2026-08-28T01:00:00Z",
      "author" => %{"id" => 90_000 + id, "node_id" => "U_#{id}", "login" => "user-#{id}"},
      "assets" =>
        if asset_count == 0 do
          []
        else
          for asset_id <- 1..asset_count do
            %{
              "id" => asset_id,
              "name" => "asset-sentinel",
              "browser_download_url" => "https://objects.example/asset-sentinel"
            }
          end
        end
    }
  end

  defp authenticated_pull_issue(_issue, nil), do: nil

  defp authenticated_pull_issue(%{} = issue, %{} = pull) do
    state_reason = if pull["state"] == "closed", do: "completed", else: nil

    issue
    |> Map.put_new("node_id", "I_#{issue["id"]}")
    |> Map.put("number", pull["number"])
    |> Map.put("title", pull["title"])
    |> Map.put("body", pull["body"])
    |> Map.put("state", pull["state"])
    |> Map.put("state_reason", state_reason)
    |> Map.put("updated_at", pull["updated_at"])
    |> Map.put_new("labels", [])
    |> Map.put_new("assignees", [])
    |> Map.put("pull_request", %{
      "url" => "https://api.github.com/repos/octocat/Hello-World/pulls/#{pull["number"]}"
    })
  end

  defp authenticated_repository(repository, true) do
    repository
    |> Map.put_new("node_id", "R_repo")
    |> Map.put_new("full_name", "octocat/Hello-World")
  end

  defp authenticated_repository(repository, false) do
    repository
    |> Map.put_new("node_id", "R_#{repository["id"]}")
    |> Map.put_new("full_name", "fork-owner/#{repository["name"]}")
  end

  defp importer_opts(stub, item) do
    [
      credential_checkout: fn callback ->
        callback.(@pat, %{
          git_login: "metadata-test",
          gate_key: {:one_time_run, item.import_run_id}
        })
      end,
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
          "releases",
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
