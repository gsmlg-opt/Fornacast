defmodule ForgeMirrors.SettingsConflictViewTest do
  use ExUnit.Case, async: false

  import ForgeMirrors.TestSupport.MirrorFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)
    organization = active_organization_mirror_fixture()
    actor = organization_owner_fixture(organization)
    first = repository_mirror_fixture(organization)
    second = repository_mirror_fixture(organization)

    for {binding, kind, resource} <- [
          {first, "git_ref", "refs/heads/main"},
          {second, "repository", "example/second"}
        ] do
      assert {:ok, _conflict} =
               ForgeMirrors.record_conflict(%{
                 organization_mirror_id: organization.id,
                 repository_mirror_id: binding.id,
                 resource_kind: kind,
                 resource_identity: resource,
                 conflict_kind: "concurrent_edit",
                 baseline_snapshot: %{"value" => "baseline"},
                 local_snapshot: %{"value" => "local"},
                 remote_snapshot: %{"value" => "remote"}
               })
    end

    %{organization: organization, actor: actor, first: first, second: second}
  end

  test "owner gets a bounded organization-scoped conflict comparison filtered by repository and type",
       c do
    assert {:ok, view} =
             ForgeMirrors.organization_conflicts(c.actor, c.organization.organization_id, %{
               "repository" => Integer.to_string(c.first.id),
               "type" => "git_ref"
             })

    assert view.filters == %{repository: c.first.id, resource: nil, type: "git_ref"}

    assert [%{repository_mirror_id: repository_id, resource_kind: "git_ref"} = conflict] =
             view.conflicts

    assert repository_id == c.first.id
    assert conflict.baseline =~ "baseline"
    assert conflict.local =~ "local"
    assert conflict.remote =~ "remote"
  end

  test "malformed and foreign filters are ignored without narrowing or exposing another organization",
       c do
    foreign = active_organization_mirror_fixture()
    foreign_repository = repository_mirror_fixture(foreign)

    for repository_filter <- [
          Integer.to_string(foreign_repository.id),
          "9999999999999999999"
        ] do
      assert {:ok, view} =
               ForgeMirrors.organization_conflicts(c.actor, c.organization.organization_id, %{
                 "repository" => repository_filter,
                 "resource" => "refs/heads/main\nforged",
                 "type" => "not-a-conflict-type"
               })

      assert view.filters == %{repository: nil, resource: nil, type: nil}

      assert Enum.map(view.conflicts, & &1.repository_mirror_id) |> Enum.sort() ==
               Enum.sort([c.first.id, c.second.id])
    end
  end

  test "comparison snapshots are truncated by the database projection", c do
    assert {:ok, _conflict} =
             ForgeMirrors.record_conflict(%{
               organization_mirror_id: c.organization.id,
               repository_mirror_id: c.first.id,
               resource_kind: "git_ref",
               resource_identity: "refs/heads/large",
               conflict_kind: "concurrent_edit",
               baseline_snapshot: %{"value" => String.duplicate("b", 10_000)},
               local_snapshot: %{"value" => String.duplicate("l", 10_000)},
               remote_snapshot: %{"value" => String.duplicate("r", 10_000)}
             })

    assert {:ok, %{conflicts: [conflict]}} =
             ForgeMirrors.organization_conflicts(c.actor, c.organization.organization_id, %{
               "resource" => "refs/heads/large"
             })

    assert byte_size(conflict.baseline) == 4_000
    assert byte_size(conflict.local) == 4_000
    assert byte_size(conflict.remote) == 4_000
  end
end
