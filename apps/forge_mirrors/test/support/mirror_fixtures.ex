defmodule ForgeMirrors.TestSupport.MirrorFixtures do
  alias Fornacast.Repo

  def organization_fixture do
    suffix = System.unique_integer([:positive, :monotonic])
    now = DateTime.utc_now(:second)

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into users (username, email, password_hash, role, state, kind, display_name, inserted_at, updated_at) values ($1, $2, $3, 'user', 'active', 'organization', $4, $5, $5) returning id",
        ["mirror-org-#{suffix}", "mirror-#{suffix}@example.test", "hash", "Mirror #{suffix}", now]
      )

    id
  end

  def user_fixture do
    suffix = System.unique_integer([:positive, :monotonic])
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
    suffix = System.unique_integer([:positive, :monotonic])
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

    {:ok, mirror} = ForgeMirrors.create_organization_mirror(Map.merge(defaults, attrs))
    mirror
  end

  def ready_organization_mirror_fixture(attrs \\ %{}) do
    mirror = organization_mirror_fixture(attrs)
    {:ok, ready} = ForgeMirrors.transition_organization_mirror(mirror, :ready_to_bootstrap)
    ready
  end

  def active_organization_mirror_fixture(attrs \\ %{}) do
    mirror = ready_organization_mirror_fixture(attrs)
    {:ok, bootstrapping} = ForgeMirrors.transition_organization_mirror(mirror, :bootstrapping)
    {:ok, catching_up} = ForgeMirrors.transition_organization_mirror(bootstrapping, :catching_up)
    {:ok, active} = ForgeMirrors.transition_organization_mirror(catching_up, :active)
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

    {:ok, mirror} = ForgeMirrors.bind_repository(Map.merge(defaults, attrs))
    {:ok, active} = ForgeMirrors.transition_repository_mirror(mirror, :active)
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
