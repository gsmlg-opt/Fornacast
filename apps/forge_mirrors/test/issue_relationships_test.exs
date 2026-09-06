defmodule ForgeMirrors.IssueRelationshipsTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeMirrors.{IssueRelationships, MirrorResourceState}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    binding = active_organization_mirror_fixture() |> repository_mirror_fixture()
    now = DateTime.utc_now(:second)

    {1, [%{id: label_id}]} =
      Repo.insert_all(
        "repository_labels",
        [
          %{
            repository_id: binding.repository_id,
            name: "bug",
            normalized_name: "bug",
            color: "aabbcc",
            default: false,
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: binding.id,
      resource_kind: :label,
      local_resource_id: label_id,
      local_resource_type: "ForgeIssues.Label",
      github_object_id: 91,
      state: :confirmed
    })
    |> Repo.insert!()

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(%{"id" => 92, "login" => "remote"}, now)

    %{binding: binding, label_id: label_id, identity: identity, now: now}
  end

  test "resolves local membership to stable provider identities", ctx do
    ref = %{kind: :github_identity, id: ctx.identity.id}

    assert {:ok,
            %{
              labels: [%{github_object_id: 91, local_label_id: id, name: "bug"}],
              assignees: [%{github_user_id: 92, ref: ^ref, login: "remote"}]
            }} =
             IssueRelationships.resolve(ctx.binding.id, :local, [ctx.label_id], [ref])

    assert id == ctx.label_id
  end

  test "remote lookup never adopts unknown labels by name", ctx do
    assert {:error, :unmapped_label} =
             IssueRelationships.resolve(
               ctx.binding.id,
               :remote,
               [%{"id" => 999, "name" => "bug"}],
               []
             )

    assert {:ok, %{labels: [%{local_label_id: id}]}} =
             IssueRelationships.resolve(
               ctx.binding.id,
               :remote,
               [%{"id" => 91, "name" => "bug"}],
               []
             )

    assert id == ctx.label_id
    other = active_organization_mirror_fixture() |> repository_mirror_fixture()

    assert {:error, :unmapped_label} =
             IssueRelationships.resolve(other.id, :local, [ctx.label_id], [])
  end

  test "known links canonicalize remote assignees and local-only users remain unmanaged", ctx do
    user = ForgeAccounts.get_user(user_fixture())

    assert {:ok, %{assignees: []}} =
             IssueRelationships.resolve(ctx.binding.id, :local, [], [
               %{kind: :local_user, id: user.id}
             ])

    {:ok, _} = ForgeAccounts.link_github_identity(user, ctx.identity)

    assert {:ok, %{assignees: [%{github_user_id: 92, ref: %{kind: :local_user, id: id}}]}} =
             IssueRelationships.resolve(ctx.binding.id, :remote, [], [
               %{"id" => 92, "login" => "remote"}
             ])

    assert id == user.id
  end

  test "remote label transport names follow the observed immutable object", ctx do
    assert {:ok, %{labels: [%{name: "renamed", local_label_id: id}]}} =
             IssueRelationships.resolve(
               ctx.binding.id,
               :remote,
               [%{"id" => 91, "name" => "renamed"}],
               []
             )

    assert id == ctx.label_id

    assert {:error, :invalid_relationships} =
             IssueRelationships.resolve(
               ctx.binding.id,
               :remote,
               [%{"id" => 91, "name" => nil}],
               []
             )
  end

  test "duplicate local representations collapse to one provider member", ctx do
    user = ForgeAccounts.get_user(user_fixture())
    {:ok, _} = ForgeAccounts.link_github_identity(user, ctx.identity)
    refs = [%{kind: :github_identity, id: ctx.identity.id}, %{kind: :local_user, id: user.id}]

    assert {:ok, %{assignees: [%{github_user_id: 92, ref: %{kind: :local_user, id: id}}]}} =
             IssueRelationships.resolve(ctx.binding.id, :local, [], refs)

    assert id == user.id
  end

  test "multiple linked identities cannot silently choose a local user's provider account", ctx do
    user = ForgeAccounts.get_user(user_fixture())
    {:ok, _} = ForgeAccounts.link_github_identity(user, ctx.identity)

    {:ok, other} =
      ForgeAccounts.observe_github_identity(%{"id" => 93, "login" => "other"}, ctx.now)

    {:ok, _} = ForgeAccounts.link_github_identity(user, other)

    assert {:error, :ambiguous_assignee_identity} =
             IssueRelationships.resolve(ctx.binding.id, :local, [], [
               %{kind: :local_user, id: user.id}
             ])
  end
end
