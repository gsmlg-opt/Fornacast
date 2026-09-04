defmodule ForgeMirrors.TestSupport.MirrorFixtures do
  import Ecto.Query

  alias Fornacast.Repo

  def organization_fixture do
    suffix = Ecto.UUID.generate()
    now = DateTime.utc_now(:second)
    owner_id = user_fixture()

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into users (username, email, password_hash, role, state, kind, display_name, inserted_at, updated_at) values ($1, $2, $3, 'user', 'active', 'organization', $4, $5, $5) returning id",
        ["mirror-org-#{suffix}", "mirror-#{suffix}@example.test", "hash", "Mirror #{suffix}", now]
      )

    Ecto.Adapters.SQL.query!(
      Repo,
      "insert into organization_members (organization_id, user_id, role, inserted_at, updated_at) values ($1, $2, 'owner', $3, $3)",
      [id, owner_id, now]
    )

    id
  end

  def organization_owner_fixture(%{organization_id: organization_id}),
    do: organization_owner_fixture(organization_id)

  def organization_owner_fixture(%{organization_mirror_id: organization_mirror_id}) do
    organization_mirror_id
    |> then(&Repo.get!(ForgeMirrors.OrganizationMirror, &1))
    |> organization_owner_fixture()
  end

  def organization_owner_fixture(organization_id) when is_integer(organization_id) do
    ForgeAccounts.User
    |> join(:inner, [user], member in ForgeAccounts.OrganizationMember,
      on: member.user_id == user.id
    )
    |> where(
      [user, member],
      member.organization_id == ^organization_id and member.role == :owner and
        user.kind == :user and user.state == :active
    )
    |> order_by([user, _member], asc: user.id)
    |> limit(1)
    |> Repo.one!()
  end

  def user_fixture do
    suffix = Ecto.UUID.generate()
    now = DateTime.utc_now(:second)

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into users (username, email, password_hash, role, state, kind, inserted_at, updated_at) values ($1, $2, $3, 'user', 'active', 'user', $4, $4) returning id",
        ["mirror-user-#{suffix}", "mirror-user-#{suffix}@example.test", "hash", now]
      )

    id
  end

  def repository_fixture(organization_id) do
    suffix = Ecto.UUID.generate()
    now = DateTime.utc_now(:second)

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into repositories (owner_user_id, slug, name, visibility, storage_path, default_branch, lifecycle, generation, write_version, inserted_at, updated_at) values ($1, $2, $2, 'private', $3, 'main', 'ready', 1, 0, $4, $4) returning id",
        [organization_id, "repo-#{suffix}", "/tmp/mirror-repo-#{suffix}.git", now]
      )

    id
  end

  def organization_mirror_fixture(attrs \\ %{}) do
    defaults = %{
      organization_id: organization_fixture(),
      provider: "github",
      github_installation_id: System.unique_integer([:positive, :monotonic]),
      github_account_id: System.unique_integer([:positive, :monotonic]),
      github_account_login: "github-org-#{System.unique_integer([:positive, :monotonic])}"
    }

    attrs = Map.merge(defaults, attrs)
    actor = organization_owner_fixture(attrs.organization_id)
    {:ok, mirror} = ForgeMirrors.create_organization_mirror(actor, attrs)
    mirror
  end

  def ready_organization_mirror_fixture(attrs \\ %{}) do
    mirror = organization_mirror_fixture(attrs)
    actor = organization_owner_fixture(mirror)

    {:ok, ready} =
      ForgeMirrors.transition_organization_mirror(actor, mirror, :ready_to_bootstrap)

    ready
  end

  def active_organization_mirror_fixture(attrs \\ %{}) do
    mirror = ready_organization_mirror_fixture(attrs)
    actor = organization_owner_fixture(mirror)

    {:ok, bootstrapping} =
      ForgeMirrors.transition_organization_mirror(actor, mirror, :bootstrapping)

    {:ok, catching_up} =
      ForgeMirrors.transition_organization_mirror(actor, bootstrapping, :catching_up)

    {:ok, active} = ForgeMirrors.transition_organization_mirror(actor, catching_up, :active)
    active
  end

  def repository_mirror_fixture(organization_mirror, attrs \\ %{}) do
    defaults = %{
      organization_mirror_id: organization_mirror.id,
      repository_id: repository_fixture(organization_mirror.organization_id),
      github_repository_id: System.unique_integer([:positive, :monotonic]),
      github_node_id: "R_#{System.unique_integer([:positive, :monotonic])}",
      github_full_name: "example/repo-#{System.unique_integer([:positive, :monotonic])}"
    }

    actor = organization_owner_fixture(organization_mirror)
    {:ok, mirror} = ForgeMirrors.bind_repository(actor, Map.merge(defaults, attrs))
    {:ok, active} = ForgeMirrors.transition_repository_mirror(actor, mirror, :active)
    active
  end

  def operation_fixture(organization_mirror, attrs \\ %{}) do
    defaults = %{
      organization_mirror_id: organization_mirror.id,
      kind: "repository.metadata",
      dedupe_key: Ecto.UUID.generate(),
      cursor: %{},
      next_attempt_at: DateTime.utc_now(:second)
    }

    {:ok, operation} = ForgeMirrors.enqueue_operation(Map.merge(defaults, attrs))
    operation
  end
end
