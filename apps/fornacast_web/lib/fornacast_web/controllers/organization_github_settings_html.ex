defmodule FornacastWeb.OrganizationGitHubSettingsHTML do
  @moduledoc false

  use FornacastWeb, :html

  alias FornacastWeb.OrganizationSettingsComponents

  @max_repositories 100
  @max_operations 50
  @max_conflicts 50

  embed_templates "organization_github_settings_html/*"

  def normalize_view(organization, view) when is_map(view) do
    normalized =
      %{
        organization: organization,
        mirror: nil,
        installation: nil,
        coverage: :none,
        missing_permissions: [],
        policy: %{},
        capabilities: %{},
        repository_counts: %{},
        repositories: [],
        operations: [],
        conflicts: [],
        webhook_health: %{},
        actions: %{}
      }
      |> Map.merge(view)
      |> Map.put(:organization, organization)

    with true <- is_map(normalized.policy),
         true <- is_map(normalized.capabilities),
         true <- is_map(normalized.repository_counts),
         true <- is_map(normalized.webhook_health),
         true <- is_map(normalized.actions),
         true <- bounded_list?(normalized.missing_permissions, 50),
         true <- bounded_list?(normalized.repositories, @max_repositories),
         true <- bounded_list?(normalized.operations, @max_operations),
         true <- bounded_list?(normalized.conflicts, @max_conflicts) do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_view}
    end
  end

  def normalize_view(_organization, _view), do: {:error, :invalid_view}

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()

  def connected?(%{mirror: mirror}), do: is_map(mirror)
  def connected?(_view), do: false

  def partial?(%{coverage: coverage}),
    do: coverage in [:partial, "partial", :selected, "selected"]

  def partial?(_view), do: false

  def degraded?(view), do: mirror_state(view) in [:degraded, :conflicted, :revoked]

  def status_label(%{mirror: nil}), do: "GitHub is not configured"

  def status_label(view) do
    case {mirror_state(view), partial?(view)} do
      {:pending_installation, _partial} -> "Installation pending"
      {:ready_to_bootstrap, _partial} -> "Review permissions and repository scope"
      {:bootstrapping, _partial} -> "Bootstrap in progress"
      {:active, true} -> "Active with partial coverage"
      {:active, false} -> "GitHub sync active"
      {:degraded, _partial} -> "GitHub sync degraded"
      {:conflicted, _partial} -> "GitHub sync has conflicts"
      {:revoked, _partial} -> "GitHub installation revoked"
      {state, _partial} -> humanize(state)
    end
  end

  def status_variant(view) do
    case mirror_state(view) do
      :active ->
        if(partial?(view), do: "warning", else: "success")

      state when state in [:degraded, :conflicted, :revoked] ->
        "error"

      state when state in [:pending_installation, :ready_to_bootstrap, :bootstrapping] ->
        "warning"

      _state ->
        "neutral"
    end
  end

  def mirror_state(%{mirror: mirror}) when is_map(mirror), do: value(mirror, :state, :unknown)
  def mirror_state(_view), do: :not_configured

  def value(map, key, default \\ nil)
  def value(map, key, default) when is_map(map), do: Map.get(map, key, default)
  def value(_map, _key, default), do: default

  def policy_value(view, key, default \\ nil),
    do: view |> value(:policy, %{}) |> value(key, default)

  def action_enabled?(view, action),
    do: view |> value(:actions, %{}) |> value(action, false) == true

  def primary_action(view) do
    cond do
      not connected?(view) and action_enabled?(view, :install) -> :install
      action_enabled?(view, :bootstrap) -> :bootstrap
      action_enabled?(view, :reconcile) -> :reconcile
      action_enabled?(view, :resume) -> :resume
      true -> nil
    end
  end

  def action_class(view, action, fallback \\ "btn-secondary") do
    if primary_action(view) == action, do: "btn-primary", else: fallback
  end

  def map_entries(map) when is_map(map),
    do: Enum.sort_by(map, fn {key, _value} -> to_string(key) end)

  def map_entries(_map), do: []

  def item_label(item, preferred_keys) when is_map(item) do
    Enum.find_value(preferred_keys, "Unknown", fn key ->
      case value(item, key) do
        label when is_binary(label) and label != "" -> label
        label when is_atom(label) and not is_nil(label) -> humanize(label)
        label when is_integer(label) -> Integer.to_string(label)
        _missing -> nil
      end
    end)
  end

  def item_label(_item, _preferred_keys), do: "Unknown"

  def pull_merge_recheckable?(conflict) when is_map(conflict) do
    value(conflict, :resource_kind) in ["pull_merge", :pull_merge] and
      value(conflict, :state) in ["open", :open] and
      is_integer(value(conflict, :id)) and value(conflict, :id) > 0 and
      is_integer(value(conflict, :lock_version)) and value(conflict, :lock_version) > 0
  end

  def pull_merge_recheckable?(_conflict), do: false

  def repository_metadata_resolvable?(conflict) when is_map(conflict) do
    value(conflict, :resource_kind) in ["repository", :repository] and
      value(conflict, :state) in ["open", :open] and
      is_integer(value(conflict, :id)) and value(conflict, :id) > 0 and
      is_integer(value(conflict, :lock_version)) and value(conflict, :lock_version) > 0
  end

  def repository_metadata_resolvable?(_conflict), do: false

  def repository_metadata_actions(conflict) do
    if repository_metadata_resolvable?(conflict) do
      case value(conflict, :conflict_kind, value(conflict, :kind)) do
        kind
        when kind in [
               "repository_archived_unrepresentable",
               "repository_internal_visibility_unrepresentable",
               "repository_archived_internal_unrepresentable"
             ] ->
          ["keep_fornacast", "external_recheck"]

        _kind ->
          ["accept_github", "keep_fornacast", "external_recheck"]
      end
    else
      []
    end
  end

  def repository_metadata_action_label("accept_github"), do: "Accept GitHub"
  def repository_metadata_action_label("keep_fornacast"), do: "Keep Fornacast and push"

  def repository_metadata_action_label("external_recheck"),
    do: "Recheck after external resolution"

  def git_conflict?(conflict) when is_map(conflict),
    do: value(conflict, :resource_kind) in ["git_ref", :git_ref]

  def git_conflict?(_conflict), do: false

  def webhook_gap?(view), do: value(value(view, :webhook_health, %{}), :gap?, false) == true

  def webhook_failed_count(view) do
    view
    |> value(:webhook_health, %{})
    |> value(:unreconciled_failed_count, 0)
    |> case do
      count when is_integer(count) and count >= 0 -> count
      _invalid -> 0
    end
  end

  def webhook_gap_label(view) do
    count = webhook_failed_count(view)
    "#{count} failed #{if(count == 1, do: "delivery", else: "deliveries")} require reconciliation"
  end

  def humanize(true), do: "Enabled"
  def humanize(false), do: "Disabled"
  def humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  def humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def humanize(value) when is_integer(value), do: Integer.to_string(value)
  def humanize(_value), do: "Unknown"

  def datetime_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def datetime_value(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  def datetime_value(_datetime), do: nil

  def datetime_label(nil), do: "Never"

  def datetime_label(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%b %d, %Y at %H:%M UTC")

  def datetime_label(%NaiveDateTime{} = datetime),
    do: Calendar.strftime(datetime, "%b %d, %Y at %H:%M UTC")

  def datetime_label(_datetime), do: "Unknown"

  defp bounded_list?(list, maximum) when is_list(list), do: bounded_list?(list, maximum, 0)
  defp bounded_list?(_list, _maximum), do: false

  defp bounded_list?([], _maximum, _count), do: true
  defp bounded_list?(_remaining, maximum, count) when count >= maximum, do: false
  defp bounded_list?([_item | rest], maximum, count), do: bounded_list?(rest, maximum, count + 1)
end
