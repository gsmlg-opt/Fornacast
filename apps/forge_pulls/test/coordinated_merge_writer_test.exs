defmodule ForgePulls.CoordinatedMergeWriterTest do
  use ExUnit.Case, async: false
  alias Ecto.{Changeset, Multi}
  alias ForgeIssues.Issue
  alias ForgePulls.{CoordinatedMerge, MergeOperation, PullRequest}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "merge-writer-#{suffix}",
        email: "merge-writer-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, repository} =
      ForgeRepos.create_repository(actor, %{name: "writer", slug: "writer", visibility: :private})

    path = ForgeRepos.absolute_storage_path(repository)
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    base = git!(path, ["commit-tree", tree, "-m", "base"])
    head = git!(path, ["commit-tree", tree, "-p", base, "-m", "head"])
    git!(path, ["update-ref", "refs/heads/main", base])
    git!(path, ["update-ref", "refs/heads/feature", head])

    {:ok, pull} =
      ForgePulls.create_pull_request(
        repository,
        actor,
        %{title: "Deterministic", head: "feature", base: "main"},
        %{request_id: "create-#{suffix}"}
      )

    {:ok, projection} = ForgePulls.sync_projection(repository.id, :pull, pull.id)

    signature = %{
      "name" => "Fixed Writer",
      "email" => "fixed@example.test",
      "seconds" => 1_750_000_000,
      "offset_minutes" => 60
    }

    request = %{
      repository_id: repository.id,
      resource_kind: :pull,
      local_resource_id: pull.id,
      expected_local_version: projection.local_version,
      expected_fields: projection.fields,
      expected_merge_state: projection.merge_state,
      expected_head_repository_id: repository.id,
      coordinator_operation_id: suffix,
      actor_user_id: actor.id,
      request_id: "writer-#{suffix}",
      commit_intent: %{
        "message" => "Exact merge\n\nDurable bytes",
        "author" => signature,
        "committer" => signature
      }
    }

    {:ok, %{intent: intent}} =
      Multi.new()
      |> ForgePulls.append_prepare_coordinated_merge(:intent, request)
      |> Repo.transaction()

    %{repository: repository, path: path, pull: pull, intent: intent, base: base, head: head}
  end

  test "writes and reuses one pinned two-parent commit without public effects", c do
    assert {:ok, written} = write(c)
    assert written.state == :merge_written
    oid = written.merge_oid
    assert git!(c.path, ["show", "-s", "--format=%P", oid]) == "#{c.base} #{c.head}"
    assert git!(c.path, ["show", "-s", "--format=%B", oid]) == c.intent.commit_intent["message"]
    assert {:ok, ^oid} = GitCore.exact_tracking_ref(c.path, namespace(c), "refs/heads/result")
    assert {:ok, replay} = write(c)
    assert replay.merge_oid == oid
    assert replay.lock_version == written.lock_version
    assert_untouched(c)
    assert git!(c.path, ["config", "--get-all", "transfer.hideRefs"]) =~ "refs/fornacast/"
  end

  for point <- [:after_object_write, :after_pin] do
    test "crash at #{point} replays identical commit bytes", c do
      point = unquote(point)

      assert_raise RuntimeError, "simulated crash", fn ->
        CoordinatedMerge.with_test_writer_hook(
          fn stage, oid ->
            if stage == point do
              send(self(), {:written_oid, oid})
              raise "simulated crash"
            end
          end,
          fn -> write(c) end
        )
      end

      assert_receive {:written_oid, oid}
      assert Repo.get!(MergeOperation, c.intent.id).merge_oid == nil
      assert_untouched(c)
      assert {:ok, replay} = write(c)
      assert replay.merge_oid == oid
      assert_untouched(c)
    end
  end

  test "missing or rejected capability and an uncommitted caller cannot write", c do
    before = git!(c.path, ["count-objects", "-v"])

    assert {:error, :invalid_coordinator_capability} =
             ForgePulls.write_coordinated_merge(
               c.intent.id,
               c.intent.coordinator_operation_id,
               []
             )

    assert {:error, :revoked} = write(c, fn _ -> {:error, :revoked} end)
    assert {:ok, {:error, :uncommitted_merge_intent}} = Repo.transaction(fn -> write(c) end)
    assert git!(c.path, ["count-objects", "-v"]) == before
    assert {:ok, nil} = GitCore.exact_tracking_ref(c.path, namespace(c), "refs/heads/result")
    assert_untouched(c)
  end

  test "tree checkpoint survives before commit and replay ignores changed merge configuration",
       c do
    assert_raise RuntimeError, "tree checkpoint crash", fn ->
      CoordinatedMerge.with_test_writer_hook(
        fn stage, _ ->
          if stage == :after_tree_checkpoint, do: raise("tree checkpoint crash")
        end,
        fn -> write(c) end
      )
    end

    checkpoint = Repo.get!(MergeOperation, c.intent.id)
    assert is_binary(checkpoint.merge_tree_oid)
    assert checkpoint.merge_oid == nil

    assert {:blocked, :claimable_operation} =
             ForgePulls.MergeRecovery.cleanup_safety_locked(
               c.repository,
               DateTime.utc_now(:second)
             )

    assert_untouched(c)
    git!(c.path, ["config", "merge.renormalize", "true"])
    git!(c.path, ["config", "core.autocrlf", "true"])
    assert {:ok, written} = write(c)

    assert git!(c.path, ["show", "-s", "--format=%T", written.merge_oid]) ==
             checkpoint.merge_tree_oid

    assert_untouched(c)
  end

  test "crash before tree checkpoint leaves no unproved pin or merge commit", c do
    assert_raise RuntimeError, "before tree checkpoint", fn ->
      CoordinatedMerge.with_test_writer_hook(
        fn stage, _ ->
          if stage == :after_tree_write, do: raise("before tree checkpoint")
        end,
        fn -> write(c) end
      )
    end

    saved = Repo.get!(MergeOperation, c.intent.id)
    assert saved.merge_tree_oid == nil
    assert saved.merge_oid == nil
    assert {:ok, nil} = GitCore.exact_tracking_ref(c.path, namespace(c), "refs/tags/tree")
    assert_untouched(c)
    git!(c.path, ["config", "merge.renormalize", "true"])
    assert {:ok, _} = write(c)
    assert_untouched(c)
  end

  test "crash after tree pin retains its previously committed tree proof", c do
    assert_raise RuntimeError, "after tree pin", fn ->
      CoordinatedMerge.with_test_writer_hook(
        fn stage, _ ->
          if stage == :after_tree_pin, do: raise("after tree pin")
        end,
        fn -> write(c) end
      )
    end

    saved = Repo.get!(MergeOperation, c.intent.id)
    assert is_binary(saved.merge_tree_oid)
    assert saved.merge_oid == nil
    assert {:ok, pinned} = GitCore.exact_tracking_ref(c.path, namespace(c), "refs/tags/tree")
    assert pinned == saved.merge_tree_oid
    assert_untouched(c)
    git!(c.path, ["config", "merge.renormalize", "true"])
    assert {:ok, written} = write(c)
    assert git!(c.path, ["show", "-s", "--format=%T", written.merge_oid]) == saved.merge_tree_oid
  end

  test "foreign pin is never replaced", c do
    assert {:ok, _} =
             ForgeRepos.with_write_fence(c.repository, :merge, fn path, remaining ->
               GitCore.compare_and_swap_tracking_ref(
                 path,
                 namespace(c),
                 "refs/heads/result",
                 nil,
                 c.base,
                 deadline_ms: remaining
               )
             end)

    assert {:error, :merge_pin_conflict} = write(c)
    assert {:ok, actual} = GitCore.exact_tracking_ref(c.path, namespace(c), "refs/heads/result")
    assert actual == c.base
    assert Repo.get!(MergeOperation, c.intent.id).merge_oid == nil
    assert_untouched(c)
  end

  test "capability is rechecked after the durable tree and before the commit", c do
    assert {:error, :revoked} =
             write(c, fn intent ->
               if is_nil(intent.merge_tree_oid), do: :ok, else: {:error, :revoked}
             end)

    saved = Repo.get!(MergeOperation, c.intent.id)
    assert is_binary(saved.merge_tree_oid)
    assert saved.merge_oid == nil
    assert {:ok, nil} = GitCore.exact_tracking_ref(c.path, namespace(c), "refs/heads/result")
    assert_untouched(c)
  end

  test "stale aggregate and wrong coordinator cannot write", c do
    assert {:error, :stale_merge_identity} =
             ForgePulls.write_coordinated_merge(
               c.intent.id,
               c.intent.coordinator_operation_id + 1,
               authorize: fn _ -> :ok end
             )

    Repo.get!(Issue, c.pull.issue_id) |> Changeset.change(sync_version: 99) |> Repo.update!()
    before = git!(c.path, ["count-objects", "-v"])
    assert {:error, _} = write(c)
    assert git!(c.path, ["count-objects", "-v"]) == before
    assert Repo.get!(MergeOperation, c.intent.id).merge_oid == nil
  end

  test "missing head object in base database is not resolved through its branch name", c do
    absent = String.duplicate("a", 40)
    pull = Repo.get!(PullRequest, c.pull.id)
    pull |> Changeset.change(head_sha: absent) |> Repo.update!()

    intent =
      c.intent
      |> Changeset.change(
        expected_head_oid: absent,
        commit_intent:
          put_in(c.intent.commit_intent, ["resource", "expected_fields", "head_sha"], absent)
      )
      |> Repo.update!()

    assert {:error, _} = write(%{c | intent: intent})
    assert Repo.get!(MergeOperation, c.intent.id).merge_oid == nil
    assert_untouched(c)
  end

  test "materializes a represented cross-repository head before writing one merge", c do
    cross = cross_repository(c)

    assert_raise RuntimeError, "after head materialization", fn ->
      CoordinatedMerge.with_test_writer_hook(
        fn stage, _oid ->
          if stage == :after_head_materialization, do: raise("after head materialization")
        end,
        fn -> write(cross) end
      )
    end

    assert git_commit_exists?(c.path, cross.head)
    assert Repo.get!(MergeOperation, cross.intent.id).merge_tree_oid == nil
    assert_untouched(cross)

    assert {:ok, written} = write(cross)

    assert git!(c.path, ["show", "-s", "--format=%P", written.merge_oid]) ==
             "#{c.base} #{cross.head}"

    _fsck_output = git!(c.path, ["fsck", "--strict"])
    assert {:ok, base} = GitCore.exact_ref(c.path, "refs/heads/main")
    assert base == c.base
    assert {:ok, head} = GitCore.exact_ref(cross.head_path, "refs/heads/feature")
    assert head == cross.head
    assert {:ok, nil} = GitCore.exact_ref(c.path, "refs/heads/feature")
    assert Repo.get!(PullRequest, cross.pull.id).merged_at == nil
  end

  test "missing exact cross-repository head fails before materialization", c do
    cross = cross_repository(c)
    File.rm!(loose_object_path(cross.head_path, cross.head))

    assert {:error, %GitCore.Error{kind: :commit_not_found}} = write(cross)
    refute git_commit_exists?(c.path, cross.head)
    assert Repo.get!(MergeOperation, cross.intent.id).merge_tree_oid == nil
    assert_untouched(cross)
  end

  test "cross-repository head generation replacement is fenced", c do
    cross = cross_repository(c)

    cross.head_repository
    |> Changeset.change(generation: cross.head_repository.generation + 1)
    |> Repo.update!()

    assert {:error, :stale_merge_identity} = write(cross)
    refute git_commit_exists?(c.path, cross.head)
    assert Repo.get!(MergeOperation, cross.intent.id).merge_tree_oid == nil
    assert_untouched(cross)
  end

  test "intent mutation during capability check and repository replacement are fenced", c do
    before = git!(c.path, ["count-objects", "-v"])

    assert {:error, :stale_merge_identity} =
             write(c, fn observed ->
               observed
               |> Changeset.change(
                 commit_intent: Map.put(observed.commit_intent, "message", "Changed")
               )
               |> Repo.update!()

               :ok
             end)

    assert Repo.get!(MergeOperation, c.intent.id).commit_intent == c.intent.commit_intent
    c.repository |> Changeset.change(generation: c.repository.generation + 1) |> Repo.update!()
    assert {:error, _} = write(c)
    assert git!(c.path, ["count-objects", "-v"]) == before
    assert_untouched(c)
  end

  defp write(c, authorize \\ fn _ -> :ok end),
    do:
      ForgePulls.write_coordinated_merge(c.intent.id, c.intent.coordinator_operation_id,
        authorize: authorize
      )

  defp namespace(c), do: "merge-#{c.intent.id}"

  defp cross_repository(c) do
    suffix = System.unique_integer([:positive])

    {:ok, head_repository} =
      ForgeRepos.create_repository(Repo.get!(ForgeAccounts.User, c.repository.owner_user_id), %{
        name: "writer-head-#{suffix}",
        slug: "writer-head-#{suffix}",
        visibility: :private
      })

    head_path = ForgeRepos.absolute_storage_path(head_repository)
    assert {:ok, pack} = GitCore.pack_objects(c.path, [c.base])
    assert {:ok, []} = GitCore.receive_pack(head_path, pack, [])

    work_path = Path.join(System.tmp_dir!(), "fornacast-merge-head-#{suffix}")
    File.mkdir_p!(work_path)
    File.write!(Path.join(work_path, "feature.txt"), "head only\n")
    on_exit(fn -> File.rm_rf(work_path) end)
    git!(head_path, ["--work-tree=#{work_path}", "add", "feature.txt"])
    tree = git!(head_path, ["write-tree"])

    head = git!(head_path, ["commit-tree", tree, "-p", c.base, "-m", "head only"])
    git!(head_path, ["update-ref", "refs/heads/feature", head])
    git!(c.path, ["update-ref", "-d", "refs/heads/feature"])
    refute git_commit_exists?(c.path, head)

    pull =
      c.pull
      |> Changeset.change(head_repository_id: head_repository.id, head_sha: head)
      |> Repo.update!()

    {:ok, projection} = ForgePulls.sync_projection(c.repository.id, :pull, pull.id)

    resource =
      c.intent.commit_intent["resource"]
      |> Map.put("expected_fields", projection.fields)
      |> Map.put("expected_local_version", projection.local_version)
      |> Map.put("head_repository_id", head_repository.id)
      |> Map.put("head_repository_generation", head_repository.generation)

    intent =
      c.intent
      |> Changeset.change(
        expected_head_oid: head,
        commit_intent: put_in(c.intent.commit_intent, ["resource"], resource)
      )
      |> Repo.update!()

    Map.merge(c, %{
      head: head,
      head_path: head_path,
      head_repository: head_repository,
      intent: intent,
      pull: pull
    })
  end

  defp assert_untouched(c) do
    assert {:ok, actual} = GitCore.exact_ref(c.path, "refs/heads/main")
    assert actual == c.base
    assert Repo.get!(PullRequest, c.pull.id).merged_at == nil
    assert Repo.get!(Issue, c.pull.issue_id).state == :open
  end

  defp git!(path, args) do
    {output, 0} =
      System.cmd("git", ["--git-dir=#{path}" | args],
        env: [
          {"GIT_AUTHOR_NAME", "Writer Fixture"},
          {"GIT_AUTHOR_EMAIL", "writer@example.test"},
          {"GIT_COMMITTER_NAME", "Writer Fixture"},
          {"GIT_COMMITTER_EMAIL", "writer@example.test"}
        ]
      )

    String.trim(output)
  end

  defp git_commit_exists?(path, oid) do
    case System.cmd("git", ["--git-dir=#{path}", "cat-file", "-e", "#{oid}^{commit}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp loose_object_path(repository_path, oid) do
    Path.join([
      repository_path,
      "objects",
      binary_part(oid, 0, 2),
      binary_part(oid, 2, byte_size(oid) - 2)
    ])
  end
end
