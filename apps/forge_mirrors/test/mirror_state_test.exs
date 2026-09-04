defmodule ForgeMirrors.MirrorStateTest do
  use ExUnit.Case, async: false

  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.Repo
  alias ForgeMirrors.{OrganizationMirror, RepositoryMirror}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization_id = organization_fixture()
    %{organization_id: organization_id}
  end

  test "organization pause and resume preserve the exact prior lifecycle", context do
    assert {:ok, mirror} =
             ForgeMirrors.create_organization_mirror(
               organization_owner_fixture(context.organization_id),
               %{
                 organization_id: context.organization_id,
                 provider: "github"
               }
             )

    assert {:ok, ready} =
             ForgeMirrors.transition_organization_mirror(
               organization_owner_fixture(mirror),
               mirror,
               :ready_to_bootstrap
             )

    assert {:ok, paused} = ForgeMirrors.pause(organization_owner_fixture(ready), ready)
    assert %OrganizationMirror{state: :paused, resume_state: :ready_to_bootstrap} = paused

    assert {:ok, resumed} = ForgeMirrors.resume(organization_owner_fixture(paused), paused)
    assert %OrganizationMirror{state: :ready_to_bootstrap, resume_state: nil} = resumed
  end

  test "a discovered repository needs both immutable identities before active", context do
    {:ok, organization_mirror} =
      ForgeMirrors.create_organization_mirror(
        organization_owner_fixture(context.organization_id),
        %{
          organization_id: context.organization_id,
          provider: "github"
        }
      )

    assert {:ok, discovered} =
             ForgeMirrors.bind_repository(
               organization_owner_fixture(organization_mirror),
               %{
                 organization_mirror_id: organization_mirror.id,
                 github_repository_id: 101
               }
             )

    assert {:error, changeset} =
             ForgeMirrors.transition_repository_mirror(
               organization_owner_fixture(discovered),
               discovered,
               :active
             )

    assert "requires both immutable identities" in errors_on(changeset).state

    repository_id = repository_fixture(context.organization_id)

    assert {:ok, bound} =
             ForgeMirrors.update_repository_mirror(
               organization_owner_fixture(discovered),
               discovered,
               %{repository_id: repository_id}
             )

    assert {:ok, %RepositoryMirror{state: :active}} =
             ForgeMirrors.transition_repository_mirror(
               organization_owner_fixture(bound),
               bound,
               :active
             )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
