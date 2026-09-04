defmodule ForgeMirrors.MirrorStateTest do
  use ExUnit.Case, async: false

  alias Fornacast.Repo
  alias ForgeMirrors.{OrganizationMirror, RepositoryMirror}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization_id = insert_organization!()
    %{organization_id: organization_id}
  end

  test "organization pause and resume preserve the exact prior lifecycle", context do
    assert {:ok, mirror} =
             ForgeMirrors.create_organization_mirror(%{
               organization_id: context.organization_id,
               provider: "github"
             })

    assert {:ok, ready} =
             ForgeMirrors.transition_organization_mirror(mirror, :ready_to_bootstrap)

    assert {:ok, paused} = ForgeMirrors.pause(ready)
    assert %OrganizationMirror{state: :paused, resume_state: :ready_to_bootstrap} = paused

    assert {:ok, resumed} = ForgeMirrors.resume(paused)
    assert %OrganizationMirror{state: :ready_to_bootstrap, resume_state: nil} = resumed
  end

  test "a discovered repository needs both immutable identities before active", context do
    {:ok, organization_mirror} =
      ForgeMirrors.create_organization_mirror(%{
        organization_id: context.organization_id,
        provider: "github"
      })

    assert {:ok, discovered} =
             ForgeMirrors.bind_repository(%{
               organization_mirror_id: organization_mirror.id,
               github_repository_id: 101
             })

    assert {:error, changeset} =
             ForgeMirrors.transition_repository_mirror(discovered, :active)

    assert "requires both immutable identities" in errors_on(changeset).state

    repository_id = insert_repository!(context.organization_id)

    assert {:ok, bound} =
             ForgeMirrors.update_repository_mirror(discovered, %{repository_id: repository_id})

    assert {:ok, %RepositoryMirror{state: :active}} =
             ForgeMirrors.transition_repository_mirror(bound, :active)
  end

  defp insert_organization! do
    now = DateTime.utc_now(:second)

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into users (username, email, password_hash, role, state, kind, display_name, inserted_at, updated_at) values ($1, $2, $3, 'user', 'active', 'organization', $4, $5, $5) returning id",
        [
          "mirror-org-#{System.unique_integer([:positive])}",
          "mirror@example.test",
          "hash",
          "Mirror",
          now
        ]
      )

    id
  end

  defp insert_repository!(organization_id) do
    suffix = System.unique_integer([:positive])
    now = DateTime.utc_now(:second)

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into repositories (owner_user_id, slug, name, visibility, storage_path, default_branch, lifecycle, generation, write_version, inserted_at, updated_at) values ($1, $2, $2, 'private', $3, 'main', 'ready', 1, 0, $4, $4) returning id",
        [organization_id, "repo-#{suffix}", "/tmp/mirror-repo-#{suffix}.git", now]
      )

    id
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
