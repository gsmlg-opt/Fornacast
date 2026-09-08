defmodule ForgeMirrors.PullEligibilityTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeMirrors.{MirrorRefState, PullEligibility, RepositoryMirror}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base = repository_mirror_fixture(organization)
    head = repository_mirror_fixture(organization)

    refs = %{
      base_ref: "refs/heads/main",
      base_sha: String.duplicate("a", 40),
      head_ref: "refs/heads/feature",
      head_sha: String.duplicate("b", 40)
    }

    base_ref = baseline(base, refs.base_ref, refs.base_sha)
    head_ref = baseline(head, refs.head_ref, refs.head_sha)

    %{
      organization: organization,
      base: base,
      head: head,
      refs: refs,
      base_ref: base_ref,
      head_ref: head_ref
    }
  end

  test "same-organization active mappings produce bounded identity and version proof", c do
    assert {:ok, proof} = PullEligibility.check(c.base.id, c.head.repository_id, c.refs)
    assert proof.base.repository_mirror_id == c.base.id
    assert proof.head.repository_mirror_id == c.head.id
    assert proof.head.github_repository_id == c.head.github_repository_id
    assert proof.head.repository_generation == 1
    assert proof.head.ref_lock_version == c.head_ref.lock_version
    assert proof.head.oid == c.refs.head_sha
    assert proof.organization_mirror_id == c.organization.id
    baseline(c.base, c.refs.head_ref, c.refs.head_sha)
    assert {:ok, same} = PullEligibility.check(c.base.id, c.base.repository_id, c.refs)
    assert same.head.repository_mirror_id == c.base.id
  end

  test "external arbitrary or other-organization head is not represented eligibility", c do
    other = repository_mirror_fixture(active_organization_mirror_fixture())
    baseline(other, c.refs.head_ref, c.refs.head_sha)

    for id <- [nil, repository_fixture(c.organization.organization_id), other.repository_id] do
      assert {:error, :ineligible_pull} = PullEligibility.check(c.base.id, id, c.refs)
    end
  end

  test "both bindings must remain active and included", c do
    for binding <- [c.base, c.head],
        attrs <- [%{state: :discovered}, %{state: :revoked}, %{inventory_included: false}] do
      binding |> Ecto.Changeset.change(attrs) |> Repo.update!()

      assert {:error, :ineligible_pull} =
               PullEligibility.check(c.base.id, c.head.repository_id, c.refs)

      Repo.get!(RepositoryMirror, binding.id)
      |> Ecto.Changeset.change(state: :active, inventory_included: true)
      |> Repo.update!()
    end
  end

  test "paused degraded or disabled connection cannot issue eligibility proof", c do
    for attrs <- [
          %{state: :paused},
          %{state: :degraded},
          %{state: :revoked},
          %{capabilities: %{"git" => "enabled", "pulls" => "disabled"}}
        ] do
      c.organization |> Ecto.Changeset.change(attrs) |> Repo.update!()

      assert {:error, :ineligible_pull} =
               PullEligibility.check(c.base.id, c.head.repository_id, c.refs)

      Repo.get!(ForgeMirrors.OrganizationMirror, c.organization.id)
      |> Ecto.Changeset.change(state: :active, capabilities: c.organization.capabilities)
      |> Repo.update!()
    end
  end

  test "each required branch needs exact confirmed local and remote OIDs", c do
    for ref <- [c.base_ref, c.head_ref],
        attrs <- [
          %{state: :pending},
          %{state: :degraded},
          %{last_remote_oid: String.duplicate("c", 40)},
          %{last_local_oid: nil},
          %{ref_kind: :tag}
        ] do
      ref |> Ecto.Changeset.change(attrs) |> Repo.update!()

      assert {:error, :ineligible_pull} =
               PullEligibility.check(c.base.id, c.head.repository_id, c.refs)

      Repo.get!(MirrorRefState, ref.id)
      |> Ecto.Changeset.change(
        state: :confirmed,
        last_local_oid: ref.confirmed_oid,
        last_remote_oid: ref.confirmed_oid,
        ref_kind: :branch
      )
      |> Repo.update!()
    end

    assert {:error, :ineligible_pull} =
             PullEligibility.check(c.base.id, c.head.repository_id, %{
               c.refs
               | head_sha: String.duplicate("d", 40)
             })

    assert {:error, :ineligible_pull} =
             PullEligibility.check(c.base.id, c.head.repository_id, %{
               c.refs
               | head_ref: "refs/heads/missing"
             })
  end

  test "live repository ownership and lifecycle are part of proof", c do
    for binding <- [c.base, c.head] do
      repository = Repo.get!(ForgeRepos.Repository, binding.repository_id)

      for attrs <- [
            %{lifecycle: :synchronizing},
            %{owner_user_id: user_fixture()},
            %{deleted_at: DateTime.utc_now(:second)}
          ] do
        repository |> Ecto.Changeset.change(attrs) |> Repo.update!()

        assert {:error, :ineligible_pull} =
                 PullEligibility.check(c.base.id, c.head.repository_id, c.refs)

        Repo.get!(ForgeRepos.Repository, repository.id)
        |> Ecto.Changeset.change(
          lifecycle: :ready,
          owner_user_id: repository.owner_user_id,
          deleted_at: nil
        )
        |> Repo.update!()
      end
    end
  end

  test "malformed IDs refs and OIDs fail closed", c do
    for refs <- [
          %{},
          %{c.refs | head_ref: "refs/tags/v1"},
          %{c.refs | head_sha: "bad"},
          Map.put(c.refs, :extra, true)
        ] do
      assert {:error, :ineligible_pull} =
               PullEligibility.check(c.base.id, c.head.repository_id, refs)
    end

    assert {:error, :ineligible_pull} =
             PullEligibility.check(9_223_372_036_854_775_808, c.head.repository_id, c.refs)
  end

  test "installation and organization ownership remain live and identity matched", c do
    installation =
      Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
        github_installation_id: c.organization.github_installation_id
      )

    for attrs <- [
          %{state: :suspended},
          %{state: :revoked},
          %{github_account_id: installation.github_account_id + 10_000}
        ] do
      installation |> Ecto.Changeset.change(attrs) |> Repo.update!()

      assert {:error, :ineligible_pull} =
               PullEligibility.check(c.base.id, c.head.repository_id, c.refs)

      Repo.get!(ForgeMirrors.GitHubAppInstallation, installation.id)
      |> Ecto.Changeset.change(state: :active, github_account_id: installation.github_account_id)
      |> Repo.update!()
    end

    owner = Repo.get!(ForgeAccounts.User, c.organization.organization_id)
    owner |> Ecto.Changeset.change(state: :disabled) |> Repo.update!()

    assert {:error, :ineligible_pull} =
             PullEligibility.check(c.base.id, c.head.repository_id, c.refs)
  end

  defp baseline(binding, name, oid) do
    %MirrorRefState{}
    |> MirrorRefState.persistence_changeset(%{
      repository_mirror_id: binding.id,
      ref_name: name,
      ref_kind: :branch,
      confirmed_oid: oid,
      last_local_oid: oid,
      last_remote_oid: oid,
      state: :confirmed,
      last_confirmed_at: DateTime.utc_now(:second)
    })
    |> Repo.insert!()
  end
end
