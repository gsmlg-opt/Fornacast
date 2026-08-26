defmodule ForgePulls.MergeReconcilerTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgePulls.{MergeOperation, MergeReconciler}
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @tag :tmp_dir
  test "non-ready high IDs neither consume the 50-repository batch nor reconcile", %{
    tmp_dir: tmp_dir
  } do
    prepare_database!()

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    owner = user_fixture()
    cleanup_fixture_on_exit(owner, tmp_dir)
    ready = ready_fixture(owner)

    hidden =
      for index <- 1..50 do
        lifecycle = if rem(index, 2) == 0, do: :importing, else: :tombstoned
        hidden_fixture(owner, ready, index, lifecycle)
      end

    assert Enum.all?(hidden, &(&1.repository.id > ready.repository.id))
    assert :ok = MergeReconciler.reconcile_pending_repositories()

    assert %MergeOperation{state: :failed, failure_reason: "effect_not_started"} =
             Repo.get!(MergeOperation, ready.operation.id)

    hidden_operation_ids = Enum.map(hidden, & &1.operation.id)

    assert 50 ==
             Repo.aggregate(
               from(operation in MergeOperation,
                 where: operation.id in ^hidden_operation_ids and operation.state == :prepared
               ),
               :count,
               :id
             )
  end

  defp ready_fixture(owner) do
    slug = unique("ready-reconciler")
    {:ok, repository} = ForgeRepos.create_repository(owner, %{name: slug, slug: slug})
    path = ForgeRepos.absolute_storage_path(repository)
    {base_oid, head_oid} = create_refs(path)

    assert {:ok, pull} =
             ForgePulls.create_pull_request(
               repository,
               owner,
               %{title: "Ready reconciler", head: "feature", base: "main"},
               %{request_id: unique("ready-pull")}
             )

    operation = operation_fixture(repository, pull, owner, base_oid, head_oid)
    %{repository: repository, pull: pull, operation: operation}
  end

  defp hidden_fixture(owner, ready, index, lifecycle) do
    slug = unique("hidden-#{index}")

    repository =
      %Repository{}
      |> Repository.import_changeset(%{
        owner_user_id: owner.id,
        slug: slug,
        name: slug,
        visibility: :private,
        storage_path: "@hidden/#{owner.id}/#{slug}.git",
        lifecycle: :importing,
        generation: 1
      })
      |> Repo.insert!()

    repository =
      if lifecycle == :importing,
        do: repository,
        else: repository |> Ecto.Changeset.change(lifecycle: lifecycle) |> Repo.update!()

    operation =
      operation_fixture(
        repository,
        ready.pull,
        owner,
        ready.operation.expected_base_oid,
        ready.operation.expected_head_oid
      )

    %{repository: repository, operation: operation}
  end

  defp operation_fixture(repository, pull, owner, base_oid, head_oid) do
    %MergeOperation{}
    |> MergeOperation.prepare_changeset(%{
      pull_request_id: pull.id,
      repository_id: repository.id,
      actor_user_id: owner.id,
      request_id: unique("reconciler-operation"),
      base_ref: "refs/heads/main",
      head_ref: "refs/heads/feature",
      expected_base_oid: base_oid,
      expected_head_oid: head_oid,
      state: :prepared
    })
    |> Repo.insert!()
  end

  defp user_fixture do
    username = unique("reconciler-owner")

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: username,
        email: "#{username}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp create_refs(path) do
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    base = git!(path, ["commit-tree", tree, "-m", "base"])
    head = git!(path, ["commit-tree", tree, "-p", base, "-m", "head"])
    _output = git!(path, ["update-ref", "refs/heads/main", base])
    _output = git!(path, ["update-ref", "refs/heads/feature", head])
    {base, head}
  end

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.test"},
      {"GIT_COMMITTER_NAME", "Fornacast Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.test"}
    ]

    case System.cmd("git", ["--git-dir=#{path}" | args], env: env, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, code} -> flunk("git failed with #{code}: #{output}")
    end
  end

  defp prepare_database! do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      Ecto.Adapters.SQL.query!(
        Repo,
        "delete from pull_merge_operations where state not in ('completed', 'failed')",
        []
      )
    end

    :ok
  end

  defp cleanup_fixture_on_exit(owner, tmp_dir) do
    unless postgres?() do
      owner_id = owner.id

      on_exit(fn ->
        File.rm_rf!(tmp_dir)

        Ecto.Adapters.SQL.query!(Repo, "delete from audit_events where actor_user_id = ?", [
          owner_id
        ])

        repository_ids =
          Repository
          |> where([repository], repository.owner_user_id == ^owner_id)
          |> select([repository], repository.id)
          |> Repo.all()

        unless repository_ids == [] do
          placeholders = Enum.map_join(repository_ids, ", ", fn _id -> "?" end)

          for table <- [
                "pull_merge_operations",
                "pull_requests",
                "issues",
                "repository_labels",
                "repository_number_sequences"
              ] do
            Ecto.Adapters.SQL.query!(
              Repo,
              "delete from #{table} where repository_id in (#{placeholders})",
              repository_ids
            )
          end

          Ecto.Adapters.SQL.query!(
            Repo,
            "delete from repositories where id in (#{placeholders})",
            repository_ids
          )
        end

        Ecto.Adapters.SQL.query!(Repo, "delete from users where id = ?", [owner_id])
      end)
    end

    :ok
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
