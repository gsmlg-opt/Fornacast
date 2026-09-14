defmodule ForgeMirrors.Settings do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.User

  alias ForgeMirrors.{
    GitHubAppInstallation,
    InventoryPolicy,
    MirrorConflict,
    MirrorOperation,
    MirrorWebhookDelivery,
    OrganizationMirror,
    RepositoryMirror
  }

  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @repository_limit 100
  @operation_limit 50
  @conflict_limit 50
  @max_id 9_223_372_036_854_775_807
  @snapshot_display_limit 4_000
  @webhook_states [:pending, :pending_unsupported, :processing, :completed, :failed, :ignored]
  @capabilities ~w(git lfs issues pulls releases)
  @all_capabilities @capabilities
  @update_states [:ready_to_bootstrap, :active, :paused, :degraded, :conflicted]
  @allowed_policy_keys ~w(
    repository_selection selected_repository_ids auto_import_new auto_create_remote
    repository_deletion_policy conflict_notification_policy capabilities
  )

  def view(%User{} = actor, organization_id) when is_integer(organization_id) do
    with {:ok, organization} <-
           ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
      case active_mirror(organization.id) do
        nil -> {:ok, disconnected_view(organization)}
        mirror -> connected_view(organization, mirror)
      end
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def view(_actor, _organization_id), do: {:error, :forbidden}

  @spec webhook_health(User.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def webhook_health(%User{} = actor, organization_id) when is_integer(organization_id) do
    with {:ok, organization} <-
           ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
      {:ok,
       case active_mirror(organization.id) do
         nil -> empty_webhook_health()
         mirror -> webhook_health_for_mirror(mirror)
       end}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def webhook_health(_actor, _organization_id), do: {:error, :forbidden}

  @spec conflicts(User.t(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
  def conflicts(%User{} = actor, organization_id, filters)
      when is_integer(organization_id) and is_map(filters) do
    with {:ok, organization} <-
           ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
      case active_mirror(organization.id) do
        nil ->
          {:ok, %{conflicts: [], filters: empty_conflict_filters(), repositories: [], types: []}}

        mirror ->
          conflict_view(mirror, filters)
      end
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def conflicts(_actor, _organization_id, _filters), do: {:error, :forbidden}

  def update(%User{} = actor, organization_id, attrs)
      when is_integer(organization_id) and is_map(attrs) do
    with {:ok, _organization} <-
           ForgeAccounts.fetch_manageable_organization(actor, organization_id),
         %OrganizationMirror{} = mirror <- active_mirror(organization_id),
         :ok <- validate_update_state(mirror),
         {:ok, policy, capabilities} <- normalize_settings(attrs),
         :ok <- validate_permissions(policy, capabilities, installation(mirror)),
         {:ok, updated} <-
           ForgeMirrors.update_organization_mirror(actor, mirror, %{
             policy: policy,
             capabilities: capabilities
           }) do
      {:ok, updated}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_request}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def update(_actor, _organization_id, _attrs), do: {:error, :forbidden}

  defp connected_view(organization, mirror) do
    installation = installation(mirror)
    repository_counts = grouped_counts(RepositoryMirror, mirror.id)
    missing_permissions = missing_permissions(mirror, installation)

    {:ok,
     %{
       organization: organization,
       mirror: mirror_view(mirror),
       installation: installation_view(installation),
       coverage: coverage(mirror, installation),
       missing_permissions: missing_permissions,
       policy: policy_view(mirror.policy),
       capabilities: capabilities_view(mirror.capabilities),
       repository_counts: repository_counts,
       repositories: repositories(mirror.id),
       operations: operations(mirror.id),
       conflicts: conflict_summaries(mirror.id),
       webhook_health: webhook_health_for_mirror(mirror),
       actions: actions(mirror, missing_permissions)
     }}
  end

  defp disconnected_view(organization) do
    %{
      organization: organization,
      mirror: nil,
      installation: nil,
      coverage: :none,
      missing_permissions: [],
      policy: %{},
      capabilities: unavailable_capabilities(),
      repository_counts: %{},
      repositories: [],
      operations: [],
      conflicts: [],
      webhook_health: empty_webhook_health(),
      actions: %{
        install: true,
        update: false,
        bootstrap: false,
        reconcile: false,
        pause: false,
        resume: false,
        disconnect: false
      }
    }
  end

  defp active_mirror(organization_id) do
    OrganizationMirror
    |> where(
      [mirror],
      mirror.organization_id == ^organization_id and mirror.provider == "github" and
        mirror.state != :revoked
    )
    |> order_by([mirror], desc: mirror.id)
    |> limit(1)
    |> Repo.one()
  end

  defp installation(%OrganizationMirror{github_installation_id: id})
       when is_integer(id) and id > 0,
       do: Repo.get_by(GitHubAppInstallation, github_installation_id: id)

  defp installation(_mirror), do: nil

  defp mirror_view(mirror) do
    %{
      id: mirror.id,
      state: mirror.state,
      last_webhook_at: mirror.last_webhook_at,
      last_reconciled_at: mirror.last_reconciled_at,
      next_reconcile_at: mirror.next_reconcile_at
    }
  end

  defp installation_view(nil), do: nil

  defp installation_view(installation) do
    %{
      account_login: installation.github_account_login,
      account_id: installation.github_account_id,
      installation_id: installation.github_installation_id,
      repository_selection: installation.repository_selection,
      permissions: installation.permissions,
      state: installation.state
    }
  end

  defp coverage(_mirror, nil), do: :none

  defp coverage(mirror, installation) do
    case {installation.repository_selection, policy_value(mirror.policy, "repository_selection")} do
      {:all, selection} when selection in [nil, "all", :all] -> :all
      _partial -> :partial
    end
  end

  defp repositories(mirror_id) do
    RepositoryMirror
    |> where([mirror], mirror.organization_mirror_id == ^mirror_id)
    |> join(:left, [mirror], repository in Repository, on: repository.id == mirror.repository_id)
    |> order_by([mirror, _repository], asc: mirror.github_full_name, asc: mirror.id)
    |> limit(@repository_limit)
    |> select([mirror, repository], %{
      id: mirror.id,
      full_name: mirror.github_full_name,
      github_repository_id: mirror.github_repository_id,
      state: mirror.state,
      visibility: repository.visibility,
      selected: mirror.inventory_included
    })
    |> Repo.all()
  end

  defp operations(mirror_id) do
    MirrorOperation
    |> where([operation], operation.organization_mirror_id == ^mirror_id)
    |> order_by([operation], desc: operation.inserted_at, desc: operation.id)
    |> limit(@operation_limit)
    |> select([operation], %{
      id: operation.id,
      kind: operation.kind,
      state: operation.state,
      attempt_count: operation.attempt_count,
      failure_class: operation.failure_class,
      next_attempt_at: operation.next_attempt_at
    })
    |> Repo.all()
  end

  defp conflict_summaries(mirror_id) do
    MirrorConflict
    |> where(
      [conflict],
      conflict.organization_mirror_id == ^mirror_id and conflict.state == :open
    )
    |> order_by([conflict], desc: conflict.inserted_at, desc: conflict.id)
    |> limit(@conflict_limit)
    |> select([conflict], %{
      id: conflict.id,
      repository_mirror_id: conflict.repository_mirror_id,
      resource_kind: conflict.resource_kind,
      resource: conflict.resource_identity,
      kind: conflict.conflict_kind,
      state: conflict.state,
      lock_version: conflict.lock_version
    })
    |> Repo.all()
  end

  defp conflict_view(mirror, raw_filters) do
    types = conflict_types(mirror.id)
    filters = normalize_conflict_filters(mirror.id, types, raw_filters)

    {:ok,
     %{
       conflicts: conflict_details(mirror.id, filters),
       filters: filters,
       repositories: repositories(mirror.id),
       types: types
     }}
  end

  defp conflict_details(mirror_id, filters) do
    MirrorConflict
    |> where(
      [conflict],
      conflict.organization_mirror_id == ^mirror_id and conflict.state == :open
    )
    |> maybe_conflict_repository(filters.repository)
    |> maybe_conflict_resource(filters.resource)
    |> maybe_conflict_type(filters.type)
    |> order_by([conflict], desc: conflict.inserted_at, desc: conflict.id)
    |> limit(@conflict_limit)
    |> select([conflict], %{
      id: conflict.id,
      repository_mirror_id: conflict.repository_mirror_id,
      resource_kind: conflict.resource_kind,
      resource_identity: conflict.resource_identity,
      conflict_kind: conflict.conflict_kind,
      state: conflict.state,
      lock_version: conflict.lock_version,
      baseline:
        fragment("left(CAST(? AS text), ?)", conflict.baseline_snapshot, ^@snapshot_display_limit),
      local:
        fragment("left(CAST(? AS text), ?)", conflict.local_snapshot, ^@snapshot_display_limit),
      remote:
        fragment("left(CAST(? AS text), ?)", conflict.remote_snapshot, ^@snapshot_display_limit)
    })
    |> Repo.all()
  end

  defp conflict_types(mirror_id) do
    MirrorConflict
    |> where(
      [conflict],
      conflict.organization_mirror_id == ^mirror_id and conflict.state == :open
    )
    |> distinct([conflict], conflict.resource_kind)
    |> order_by([conflict], asc: conflict.resource_kind)
    |> limit(@conflict_limit)
    |> select([conflict], conflict.resource_kind)
    |> Repo.all()
  end

  defp normalize_conflict_filters(mirror_id, types, raw_filters) do
    %{
      repository: scoped_repository_id(mirror_id, Map.get(raw_filters, "repository")),
      resource: bounded_filter(Map.get(raw_filters, "resource")),
      type: normalize_type(Map.get(raw_filters, "type"), types)
    }
  end

  defp empty_conflict_filters, do: %{repository: nil, resource: nil, type: nil}

  defp scoped_repository_id(mirror_id, value) do
    with {:ok, id} <- positive_id(value),
         %RepositoryMirror{} <-
           Repo.one(
             from(repository in RepositoryMirror,
               where: repository.id == ^id and repository.organization_mirror_id == ^mirror_id,
               select: repository
             )
           ) do
      id
    else
      _invalid -> nil
    end
  end

  defp positive_id(value) when is_binary(value) and byte_size(value) in 1..19 do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= @max_id -> {:ok, id}
      _invalid -> {:error, :invalid_filter}
    end
  end

  defp positive_id(_value), do: {:error, :invalid_filter}

  defp bounded_filter(value) when is_binary(value) and byte_size(value) in 1..512 do
    if value == String.trim(value) and String.valid?(value) and
         not String.contains?(value, ["\n", "\r", "\0"]),
       do: value,
       else: nil
  end

  defp bounded_filter(_value), do: nil

  defp normalize_type(value, types) do
    if value in types, do: value, else: nil
  end

  defp maybe_conflict_repository(query, nil), do: query

  defp maybe_conflict_repository(query, repository_id),
    do: where(query, [conflict], conflict.repository_mirror_id == ^repository_id)

  defp maybe_conflict_resource(query, nil), do: query

  defp maybe_conflict_resource(query, resource),
    do: where(query, [conflict], conflict.resource_identity == ^resource)

  defp maybe_conflict_type(query, nil), do: query

  defp maybe_conflict_type(query, type),
    do: where(query, [conflict], conflict.resource_kind == ^type)

  defp webhook_health_for_mirror(%OrganizationMirror{} = mirror) do
    state_counts =
      MirrorWebhookDelivery
      |> where([delivery], delivery.organization_mirror_id == ^mirror.id)
      |> group_by([delivery], delivery.state)
      |> select([delivery], {delivery.state, count(delivery.id)})
      |> Repo.all()
      |> Map.new()
      |> then(&Map.merge(empty_webhook_health().state_counts, &1))

    oldest_unprocessed_at =
      MirrorWebhookDelivery
      |> where(
        [delivery],
        delivery.organization_mirror_id == ^mirror.id and
          delivery.state in [:pending, :pending_unsupported, :processing]
      )
      |> select([delivery], min(delivery.received_at))
      |> Repo.one()

    latest_failure =
      MirrorWebhookDelivery
      |> where(
        [delivery],
        delivery.organization_mirror_id == ^mirror.id and delivery.state == :failed
      )
      |> order_by([delivery], desc: delivery.processed_at, desc: delivery.id)
      |> limit(1)
      |> select([delivery], %{
        failure_class: delivery.failure_class,
        received_at: delivery.received_at,
        failed_at: delivery.processed_at
      })
      |> Repo.one()

    unreconciled_failed_count =
      MirrorWebhookDelivery
      |> where(
        [delivery],
        delivery.organization_mirror_id == ^mirror.id and delivery.state == :failed
      )
      |> maybe_after_reconciliation(mirror.last_reconciled_at)
      |> Repo.aggregate(:count, :id)

    %{
      state_counts: state_counts,
      oldest_unprocessed_at: oldest_unprocessed_at,
      latest_failure: latest_failure,
      unreconciled_failed_count: unreconciled_failed_count,
      gap?: unreconciled_failed_count > 0
    }
  end

  defp maybe_after_reconciliation(query, nil), do: query

  defp maybe_after_reconciliation(query, %DateTime{} = last_reconciled_at),
    do: where(query, [delivery], delivery.received_at > ^last_reconciled_at)

  defp empty_webhook_health do
    %{
      state_counts: Map.new(@webhook_states, &{&1, 0}),
      oldest_unprocessed_at: nil,
      latest_failure: nil,
      unreconciled_failed_count: 0,
      gap?: false
    }
  end

  defp grouped_counts(schema, mirror_id) do
    schema
    |> where([record], record.organization_mirror_id == ^mirror_id)
    |> group_by([record], record.state)
    |> select([record], {record.state, count(record.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp missing_permissions(mirror, installation) do
    missing_permissions(mirror.policy, mirror.capabilities, installation)
  end

  defp missing_permissions(policy, capabilities, installation) do
    required = required_permissions(policy, capabilities)

    required
    |> Enum.reject(fn {permission, expected} ->
      permission_granted?(installation, permission, expected)
    end)
    |> Enum.map(fn {permission, expected} -> "#{permission}:#{expected}" end)
  end

  defp required_permissions(policy, capabilities) do
    enabled = enabled_capabilities(capabilities)

    []
    |> maybe_require("metadata", "read", true)
    |> maybe_require(
      "contents",
      "write",
      "git" in enabled or "lfs" in enabled or "releases" in enabled
    )
    |> maybe_require("issues", "write", "issues" in enabled)
    |> maybe_require("pull_requests", "write", "pulls" in enabled)
    |> maybe_require(
      "administration",
      "write",
      "git" in enabled or policy_value(policy, "auto_create_remote_repositories") == true
    )
    |> Enum.uniq()
  end

  defp maybe_require(required, permission, access, true), do: [{permission, access} | required]
  defp maybe_require(required, _permission, _access, false), do: required

  defp permission_granted?(%GitHubAppInstallation{permissions: permissions}, permission, "read"),
    do: Map.get(permissions, permission) in ["read", "write"]

  defp permission_granted?(%GitHubAppInstallation{permissions: permissions}, permission, "write"),
    do: Map.get(permissions, permission) == "write"

  defp permission_granted?(_installation, _permission, _expected), do: false

  defp actions(mirror, missing_permissions) do
    state = mirror.state

    %{
      install: state == :pending_installation and is_nil(mirror.github_installation_id),
      update: state not in [:pending_installation, :bootstrapping, :catching_up],
      bootstrap:
        state == :ready_to_bootstrap and missing_permissions == [] and
          bootstrap_capabilities_enabled?(mirror.capabilities),
      reconcile: state in [:ready_to_bootstrap, :active, :degraded, :conflicted],
      pause:
        state in [
          :ready_to_bootstrap,
          :bootstrapping,
          :catching_up,
          :active,
          :degraded,
          :conflicted
        ],
      resume: state == :paused,
      disconnect: true
    }
  end

  defp normalize_settings(attrs) do
    with :ok <- exact_keys(attrs),
         {:ok, repository_selection} <- selection(value(attrs, "repository_selection")),
         {:ok, selected_ids} <- selected_ids(value(attrs, "selected_repository_ids", [])),
         :ok <- validate_selection(repository_selection, selected_ids),
         {:ok, auto_import} <- boolean(value(attrs, "auto_import_new")),
         {:ok, auto_create} <- boolean(value(attrs, "auto_create_remote")),
         {:ok, deletion_policy} <-
           enum(value(attrs, "repository_deletion_policy"), ~w(retain tombstone)),
         {:ok, notification_policy} <-
           enum(value(attrs, "conflict_notification_policy"), ~w(notify dashboard_only)),
         {:ok, enabled} <- capabilities(value(attrs, "capabilities", [])),
         {:ok, _inventory_policy} <-
           InventoryPolicy.parse(%{
             repository_selection: repository_selection,
             selected_repository_ids: selected_ids,
             auto_import_new_repositories: auto_import
           }) do
      policy = %{
        "repository_selection" => repository_selection,
        "selected_repository_ids" => selected_ids,
        "auto_import_new_repositories" => auto_import,
        "auto_create_remote_repositories" => auto_create,
        "repository_deletion_policy" => deletion_policy,
        "conflict_notification_policy" => notification_policy
      }

      capability_states =
        Map.new(@all_capabilities, fn capability ->
          state = if capability in enabled, do: "enabled", else: "disabled"

          {capability, state}
        end)

      {:ok, policy, capability_states}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp exact_keys(attrs) do
    keys = Enum.map(Map.keys(attrs), &to_string/1)

    if length(keys) == length(Enum.uniq(keys)) and
         Enum.sort(keys) == Enum.sort(@allowed_policy_keys),
       do: :ok,
       else: {:error, :invalid_request}
  rescue
    _exception -> {:error, :invalid_request}
  end

  defp selection(value) when value in ["all", :all], do: {:ok, "all"}
  defp selection(value) when value in ["selected", :selected], do: {:ok, "selected"}
  defp selection(_value), do: {:error, :invalid_request}

  defp selected_ids(values) when is_list(values) and length(values) <= 10_001 do
    values
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, ids} ->
      case canonical_id(value) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids} ->
        ids = Enum.reverse(ids)
        if length(ids) == length(Enum.uniq(ids)), do: {:ok, ids}, else: :error

      :error ->
        {:error, :invalid_request}
    end
  end

  defp selected_ids(_values), do: {:error, :invalid_request}

  defp validate_selection("selected", []), do: {:error, :invalid_request}
  defp validate_selection(_repository_selection, _selected_ids), do: :ok

  defp canonical_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp canonical_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 ->
        if Integer.to_string(id) == value, do: {:ok, id}, else: :error

      _invalid ->
        :error
    end
  end

  defp canonical_id(_value), do: :error

  defp boolean(value) when value in [true, "true"], do: {:ok, true}
  defp boolean(value) when value in [false, "false"], do: {:ok, false}
  defp boolean(_value), do: {:error, :invalid_request}

  defp enum(value, allowed) when is_atom(value), do: enum(Atom.to_string(value), allowed)

  defp enum(value, allowed),
    do: if(value in allowed, do: {:ok, value}, else: {:error, :invalid_request})

  defp capabilities(values) when is_list(values) and length(values) <= length(@capabilities) do
    values = Enum.map(values, &to_string/1)

    if length(values) == length(Enum.uniq(values)) and values -- @capabilities == [],
      do: {:ok, values},
      else: {:error, :invalid_request}
  rescue
    _exception -> {:error, :invalid_request}
  end

  defp capabilities(_values), do: {:error, :invalid_request}

  defp validate_update_state(%OrganizationMirror{state: state}) when state in @update_states,
    do: :ok

  defp validate_update_state(%OrganizationMirror{}), do: {:error, :invalid_transition}

  defp validate_permissions(policy, capabilities, installation) do
    if missing_permissions(policy, capabilities, installation) == [],
      do: :ok,
      else: {:error, :missing_permissions}
  end

  defp bootstrap_capabilities_enabled?(capabilities) do
    enabled = enabled_capabilities(capabilities)
    Enum.all?(@capabilities, &(&1 in enabled))
  end

  defp policy_view(policy) do
    %{
      repository_selection: policy_value(policy, "repository_selection") || "all",
      auto_import_new: policy_value(policy, "auto_import_new_repositories") || false,
      auto_create_remote: policy_value(policy, "auto_create_remote_repositories") || false,
      repository_deletion_policy: policy_value(policy, "repository_deletion_policy") || "retain",
      conflict_notification_policy:
        policy_value(policy, "conflict_notification_policy") || "dashboard_only"
    }
  end

  defp capabilities_view(capabilities) do
    Map.merge(unavailable_capabilities(), capabilities || %{})
  end

  defp enabled_capabilities(capabilities) do
    capabilities
    |> capabilities_view()
    |> Enum.filter(fn {_capability, state} ->
      state in [true, :enabled, :active, "enabled", "active"]
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp unavailable_capabilities,
    do: %{
      "git" => "disabled",
      "issues" => "disabled",
      "pulls" => "disabled",
      "lfs" => "disabled",
      "releases" => "disabled"
    }

  defp policy_value(policy, key),
    do: Map.get(policy || %{}, key, Map.get(policy || %{}, String.to_atom(key)))

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, String.to_atom(key), default))
end
