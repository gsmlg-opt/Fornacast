defmodule ForgeMirrors.PullMergeLocalLabelEffects do
  @moduledoc """
  Durable local-label prerequisites subordinate to a coordinated merge.

  A label create is never allowed to replace the merge's own external-effect
  evidence. The composite marker retains that evidence verbatim and restores it
  after the label identity is confirmed.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias Fornacast.Repo

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorConflict,
    MirrorOperation,
    MirrorResourceState,
    PullMergeBoundary,
    PullMergeConfirmation,
    RepositoryMirror
  }

  @max_id 9_223_372_036_854_775_807
  @candidate_keys [
    :fields,
    :local_resource_id,
    :local_resource_type,
    :local_version,
    :repository_id,
    :resource_kind
  ]
  @effect_keys ~w(action expected_local_fingerprint expected_local_version expected_remote_absent label_name local_label_id observed_issue_updated_at observed_pull_updated_at proposed_fingerprint proposed_snapshot resource_kind v)

  def preflight(%MirrorOperation{kind: "merge.pull"} = operation, %DateTime{} = now) do
    with :ok <- valid_utc(now) do
      Repo.transaction(fn ->
        with {:ok, context} <- PullMergeConfirmation.context(operation, now),
             true <- context.operation.external_effect_marker == operation.external_effect_marker,
             :ok <- require_write_permission(context.github_installation_id) do
          context
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_label_effect)
        end
      end)
    end
  end

  def preflight(_, _), do: {:error, :invalid_argument}

  def mark(
        %MirrorOperation{kind: "merge.pull"} = operation,
        %DateTime{} = now,
        intent,
        observation,
        candidate
      )
      when is_map(intent) and is_map(observation) and is_map(candidate) do
    with :ok <- valid_candidate(candidate), :ok <- valid_utc(now) do
      Repo.transaction(fn ->
        with {:ok, context} <- PullMergeConfirmation.context(operation, now),
             true <-
               context.operation.external_effect_marker == operation.external_effect_marker,
             :ok <- require_write_permission(context.github_installation_id),
             :ok <- authorize(operation, now, intent, observation),
             :ok <- safe_parent_phase(context, observation, candidate),
             {:ok, actual} <- exact_candidate(context, candidate, :exact),
             :ok <- assigned_lowest_unmapped(context, candidate.local_resource_id),
             :ok <- mapping_absent(context, candidate.local_resource_id),
             effect <- effect(candidate, observation),
             {:ok, marked} <-
               PullMergeBoundary.replace_local_label_marker(
                 operation,
                 now,
                 context.operation.external_effect_marker,
                 effect
               ) do
          %{operation: marked, candidate: actual}
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_label_effect)
        end
      end)
    end
  end

  def mark(_, _, _, _, _), do: {:error, :invalid_argument}

  def context(%MirrorOperation{kind: "merge.pull"} = operation, %DateTime{} = now) do
    with :ok <- valid_utc(now) do
      Repo.transaction(fn ->
        with {:ok, merge} <- PullMergeConfirmation.context(operation, now),
             true <- merge.operation.external_effect_marker == operation.external_effect_marker,
             %{"phase" => "metadata_label_pending", "label_effect" => effect} = marker <-
               merge.operation.external_effect_marker,
             true <- valid_marker?(marker),
             :ok <- require_write_permission(merge.github_installation_id),
             candidate <- candidate(effect, merge.repository_id),
             {:ok, current, label_conflict} <- recovery_candidate(merge, candidate),
             :ok <- mapping_absent(merge, candidate.local_resource_id),
             {:ok, fresh} <- PullMergeConfirmation.context(operation, now),
             true <- fresh.operation.external_effect_marker == marker do
          Map.merge(fresh, %{
            marker: marker,
            candidate: candidate,
            current_candidate: current,
            label_conflict: label_conflict
          })
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_label_effect)
        end
      end)
    end
  end

  def context(_, _), do: {:error, :invalid_argument}

  def confirm(
        %MirrorOperation{kind: "merge.pull"} = operation,
        %DateTime{} = now,
        intent,
        observation,
        candidate,
        confirmation,
        domain_multi_fun
      )
      when is_map(intent) and is_map(observation) and is_map(candidate) and
             is_map(confirmation) and is_function(domain_multi_fun, 1) do
    with :ok <- valid_candidate(candidate),
         :ok <- valid_confirmation(candidate, confirmation),
         :ok <- valid_utc(now) do
      Repo.transaction(fn ->
        with {:ok, before} <- confirmation_context(operation, now, candidate),
             :ok <- require_write_permission(before.github_installation_id),
             :ok <- authorize(operation, now, intent, observation),
             :ok <- safe_parent_phase(before, observation, candidate),
             :ok <- label_observation_current(before, observation),
             :ok <- assigned_for_confirmation(before, candidate.local_resource_id),
             :ok <- mapping_absent(before, candidate.local_resource_id),
             :ok <- identity_available(before, confirmation, nil),
             admission <- admission(before.repository_id),
             {:ok, %{resource: projection}} <-
               Repo.transaction(domain_multi_fun.(Multi.new())),
             :ok <- verify_projection(projection, before, candidate, admission),
             {:ok, fresh} <- confirmation_context(operation, now, candidate),
             :ok <- require_write_permission(fresh.github_installation_id),
             :ok <- unchanged_context(before, fresh),
             :ok <- authorize(operation, now, intent, observation),
             :ok <- safe_parent_phase(fresh, observation, candidate),
             :ok <- label_observation_current(fresh, observation),
             :ok <- assigned_for_confirmation(fresh, candidate.local_resource_id),
             :ok <- mapping_absent(fresh, candidate.local_resource_id),
             :ok <- identity_available(fresh, confirmation, nil),
             {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(candidate_fields(candidate)),
             {:ok, mapping} <- insert_mapping(fresh, candidate, confirmation, fingerprint),
             :ok <- identity_available(fresh, confirmation, mapping.id),
             {:ok, yielded} <-
               PullMergeBoundary.finish_local_label_marker(
                 fresh.operation,
                 now,
                 fresh.operation.external_effect_marker,
                 parent_marker(fresh.operation.external_effect_marker)
               ) do
          %{
            operation: yielded,
            resource_state: mapping,
            resource: candidate
          }
        else
          {:error, _, reason, _} -> Repo.rollback(reason)
          {:error, reason} -> Repo.rollback(reason)
          false -> Repo.rollback(:stale_label_effect)
          _ -> Repo.rollback(:invalid_projection)
        end
      end)
    end
  end

  def confirm(_, _, _, _, _, _, _), do: {:error, :invalid_argument}

  def conflict(
        %MirrorOperation{kind: "merge.pull"} = operation,
        %DateTime{} = now,
        intent,
        observation,
        candidate,
        kind,
        remote
      )
      when is_map(intent) and is_map(observation) and is_map(candidate) and is_atom(kind) and
             is_map(remote) do
    with :ok <- valid_candidate(candidate),
         :ok <- valid_conflict_input(operation, kind, remote),
         :ok <- valid_utc(now) do
      Repo.transaction(fn ->
        with {:ok, context} <- conflict_context(operation, now, candidate),
             :ok <- require_write_permission(context.github_installation_id),
             :ok <- authorize(operation, now, intent, observation),
             :ok <- safe_parent_phase(context, observation, candidate),
             :ok <- label_observation_current(context, observation),
             :ok <- assigned_for_confirmation(context, candidate.local_resource_id),
             :ok <- mapping_absent(context, candidate.local_resource_id),
             :ok <- validate_deterministic_conflict(context, candidate, kind, remote),
             {:ok, conflict} <- record_conflict(context, candidate, kind, remote),
             {:ok, yielded} <-
               PullMergeBoundary.release_local_label_conflict(
                 context.operation,
                 now,
                 context.operation.external_effect_marker,
                 Atom.to_string(kind)
               ) do
          %{operation: yielded, conflict: conflict}
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_label_effect)
        end
      end)
    end
  end

  def conflict(_, _, _, _, _, _, _), do: {:error, :invalid_argument}

  @doc false
  def valid_marker?(
        %{
          "phase" => "metadata_label_pending",
          "parent_marker" => parent,
          "label_effect" => effect
        } = marker
      )
      when map_size(marker) == 3 and is_map(parent) and is_map(effect) do
    Enum.sort(Map.keys(effect)) == Enum.sort(@effect_keys) and
      effect["v"] == 1 and effect["action"] == "create_remote_label" and
      effect["resource_kind"] == "label" and effect["expected_remote_absent"] == true and
      valid_id?(effect["local_label_id"]) and valid_id?(effect["expected_local_version"]) and
      valid_fields?(effect["proposed_snapshot"]) and
      effect["label_name"] == effect["proposed_snapshot"]["name"] and
      valid_fingerprint?(effect["expected_local_fingerprint"]) and
      effect["proposed_fingerprint"] == effect["expected_local_fingerprint"] and
      fingerprint?(effect["proposed_snapshot"], effect["expected_local_fingerprint"]) and
      utc_iso8601?(effect["observed_pull_updated_at"]) and
      utc_iso8601?(effect["observed_issue_updated_at"])
  end

  def valid_marker?(_), do: false

  defp confirmation_context(operation, now, candidate) do
    with {:ok, context} <- PullMergeConfirmation.context(operation, now),
         true <- context.operation.external_effect_marker == operation.external_effect_marker,
         marker when is_map(marker) <- context.operation.external_effect_marker do
      case marker do
        %{"phase" => "metadata_label_pending", "label_effect" => effect} ->
          with true <- valid_marker?(marker),
               true <- candidate(effect, context.repository_id) == candidate,
               {:ok, _current} <- exact_candidate(context, candidate, :minimum) do
            {:ok, Map.put(context, :label_marker, marker)}
          else
            _ -> {:error, :invalid_label_effect}
          end

        %{"phase" => phase} when phase in ["remote_cas_pending", "metadata_issue_pending"] ->
          with {:ok, _current} <- exact_candidate(context, candidate, :exact) do
            {:ok, Map.put(context, :label_marker, nil)}
          end

        _ ->
          {:error, :invalid_label_effect}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_label_effect}
    end
  end

  defp conflict_context(operation, now, candidate) do
    with {:ok, context} <- PullMergeConfirmation.context(operation, now),
         true <- context.operation.external_effect_marker == operation.external_effect_marker,
         marker when is_map(marker) <- context.operation.external_effect_marker do
      case marker do
        %{"phase" => "metadata_label_pending", "label_effect" => effect} ->
          if valid_marker?(marker) and candidate(effect, context.repository_id) == candidate,
            do: {:ok, Map.put(context, :label_marker, marker)},
            else: {:error, :invalid_label_effect}

        %{"phase" => phase} when phase in ["remote_cas_pending", "metadata_issue_pending"] ->
          with {:ok, _current} <- exact_candidate(context, candidate, :exact) do
            {:ok, Map.put(context, :label_marker, nil)}
          end

        _ ->
          {:error, :invalid_label_effect}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_label_effect}
    end
  end

  defp safe_parent_phase(context, observation, _candidate) do
    marker = parent_marker(context.operation.external_effect_marker)

    case marker do
      %{"phase" => "remote_cas_pending"} ->
        if is_nil(context.metadata_intent), do: :ok, else: {:error, :stale_label_effect}

      %{"phase" => "metadata_issue_pending"} ->
        metadata = context.metadata_intent

        with %{local_version: version, payload: payload} <- metadata,
             {:ok, local} <- current_pull(context),
             true <- local.local_version > version,
             true <- observation.issue.confirmed_snapshot == payload["target_issue"],
             true <- observation_current?(observation, marker) do
          :ok
        else
          _ -> {:error, :ambiguous_external_effect}
        end

      _ ->
        {:error, :invalid_label_effect}
    end
  end

  defp authorize(operation, now, intent, observation),
    do: PullMergeConfirmation.authorize_effect_observation(operation, now, intent, observation)

  defp current_pull(context) do
    with {:ok, local} <-
           apply(ForgePulls, :sync_projection, [
             context.repository_id,
             :pull,
             context.expected.pull_id
           ]),
         true <-
           local.local_resource_id == context.expected.pull_id and
             local.issue_id == context.expected.issue_id and
             local.local_version >= context.expected.local_version do
      {:ok, local}
    else
      _ -> {:error, :stale_label_effect}
    end
  end

  defp label_observation_current(
         %{operation: %{external_effect_marker: %{"phase" => "metadata_label_pending"} = marker}},
         observation
       ) do
    effect = marker["label_effect"]

    with {:ok, pull_time, 0} <- DateTime.from_iso8601(effect["observed_pull_updated_at"]),
         {:ok, issue_time, 0} <- DateTime.from_iso8601(effect["observed_issue_updated_at"]),
         true <- DateTime.compare(observation.pull.remote_updated_at, pull_time) != :lt,
         true <- DateTime.compare(observation.issue.remote_updated_at, issue_time) != :lt do
      :ok
    else
      _ -> {:error, :stale_label_effect}
    end
  end

  defp label_observation_current(_context, _observation), do: :ok

  defp exact_candidate(context, candidate, mode) do
    fields = candidate_fields(candidate)

    row =
      Repo.one(
        from label in "repository_labels",
          where:
            label.repository_id == ^context.repository_id and
              label.id == ^candidate.local_resource_id,
          select: %{
            repository_id: label.repository_id,
            resource_kind: :label,
            local_resource_type: "ForgeIssues.Label",
            local_resource_id: label.id,
            local_version: label.sync_version,
            name: label.name,
            color: label.color,
            description: label.description
          },
          lock: "FOR UPDATE"
      )
      |> normalize_label_row()

    valid =
      case {row, mode} do
        {%{local_version: version} = actual, :exact} ->
          version == candidate.local_version and actual == candidate and
            candidate_fields(actual) == fields

        {%{local_version: version} = actual, :minimum} ->
          version >= candidate.local_version and
            (version > candidate.local_version or candidate_fields(actual) == fields)

        _ ->
          false
      end

    if valid, do: {:ok, row}, else: {:error, :label_metadata_conflict}
  end

  defp recovery_candidate(context, candidate) do
    case exact_candidate(context, candidate, :minimum) do
      {:ok, current} -> {:ok, current, nil}
      {:error, :label_metadata_conflict} -> {:ok, nil, :label_metadata_conflict}
    end
  end

  defp assigned_for_confirmation(
         %{operation: %{external_effect_marker: %{"phase" => "metadata_label_pending"}}},
         _label_id
       ),
       do: :ok

  defp assigned_for_confirmation(context, label_id),
    do: assigned_lowest_unmapped(context, label_id)

  defp assigned_lowest_unmapped(context, label_id) do
    assigned =
      Repo.all(
        from membership in "issue_labels",
          join: label in "repository_labels",
          on: label.id == membership.label_id,
          where:
            membership.issue_id == ^context.expected.issue_id and
              label.repository_id == ^context.repository_id,
          order_by: label.id,
          select: label.id,
          lock: "FOR UPDATE"
      )

    mapped =
      Repo.all(
        from mapping in MirrorResourceState,
          where:
            mapping.repository_mirror_id == ^context.repository_mirror_id and
              mapping.resource_kind == :label and mapping.state == :confirmed and
              not is_nil(mapping.github_object_id) and mapping.local_resource_id in ^assigned,
          order_by: mapping.local_resource_id,
          select: mapping.local_resource_id,
          lock: "FOR UPDATE"
      )

    if Enum.find(assigned, &(&1 not in mapped)) == label_id,
      do: :ok,
      else: {:error, :label_not_assigned}
  end

  defp mapping_absent(context, local_id) do
    mapping =
      Repo.one(
        from mapping in MirrorResourceState,
          where:
            mapping.repository_mirror_id == ^context.repository_mirror_id and
              mapping.resource_kind == :label and mapping.local_resource_id == ^local_id,
          lock: "FOR UPDATE"
      )

    if is_nil(mapping), do: :ok, else: {:error, :stale_label_effect}
  end

  defp identity_available(context, confirmation, own_id) do
    own_id = own_id || 0

    remote_collision =
      Repo.exists?(
        from mapping in MirrorResourceState,
          where:
            mapping.repository_mirror_id == ^context.repository_mirror_id and
              mapping.resource_kind == :label and
              mapping.github_object_id == ^confirmation.github_object_id and mapping.id != ^own_id
      )

    node_collision =
      Repo.exists?(
        from mapping in MirrorResourceState,
          join: binding in RepositoryMirror,
          on: binding.id == mapping.repository_mirror_id,
          where:
            binding.organization_mirror_id == ^context.organization_mirror_id and
              mapping.resource_kind == :label and
              mapping.github_node_id == ^confirmation.github_node_id and mapping.id != ^own_id
      )

    if remote_collision or node_collision,
      do: {:error, :identity_conflict},
      else: :ok
  end

  defp admission(repository_id) do
    %{
      label: maximum_id("repository_labels", repository_id),
      issue: maximum_id("issues", repository_id),
      pull: maximum_id("pull_requests", repository_id)
    }
  end

  defp maximum_id(table, repository_id) do
    Repo.one(from row in table, where: row.repository_id == ^repository_id, select: max(row.id)) ||
      0
  end

  defp verify_projection(projection, context, candidate, before) when is_map(projection) do
    with {:ok, actual} <- exact_candidate(context, candidate, :minimum),
         true <- projection == actual,
         true <- maximum_id("repository_labels", context.repository_id) == before.label,
         true <- maximum_id("issues", context.repository_id) == before.issue,
         true <- maximum_id("pull_requests", context.repository_id) == before.pull do
      :ok
    else
      _ -> {:error, :invalid_projection}
    end
  end

  defp verify_projection(_, _, _, _), do: {:error, :invalid_projection}

  defp insert_mapping(context, candidate, confirmation, fingerprint) do
    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: context.repository_mirror_id,
      resource_kind: :label,
      local_resource_type: "ForgeIssues.Label",
      local_resource_id: candidate.local_resource_id,
      github_object_id: confirmation.github_object_id,
      github_node_id: confirmation.github_node_id,
      confirmed_local_version: candidate.local_version,
      confirmed_snapshot: candidate_fields(candidate),
      confirmed_fingerprint: fingerprint,
      state: :confirmed,
      lock_version: 1
    })
    |> Repo.insert()
  end

  defp unchanged_context(before, after_context) do
    fields = [
      :repository_id,
      :repository_mirror_id,
      :organization_mirror_id,
      :github_installation_id,
      :intent,
      :expected,
      :provider_pull_identity,
      :metadata_intent
    ]

    if Map.take(before, fields) == Map.take(after_context, fields) and
         before.operation.external_effect_marker == after_context.operation.external_effect_marker,
       do: :ok,
       else: {:error, :stale_label_effect}
  end

  defp record_conflict(context, candidate, kind, remote) do
    attrs = %{
      organization_mirror_id: context.organization_mirror_id,
      repository_mirror_id: context.repository_mirror_id,
      resource_kind: "pull_merge",
      resource_identity: to_string(context.intent.id),
      conflict_kind: Atom.to_string(kind),
      baseline_snapshot: %{
        "parent_marker" => parent_marker(context.operation.external_effect_marker),
        "expected_remote_absent" => true
      },
      local_snapshot: %{"label" => candidate_fields(candidate)},
      remote_snapshot: %{"label" => remote}
    }

    %MirrorConflict{} |> MirrorConflict.record_changeset(attrs) |> Repo.insert()
  end

  defp require_write_permission(installation_id) do
    case Repo.one(
           from installation in GitHubAppInstallation,
             where: installation.github_installation_id == ^installation_id,
             lock: "FOR UPDATE"
         ) do
      %{state: :active, permissions: %{"pull_requests" => "write"}} -> :ok
      %{state: :active} -> {:error, :permission_missing}
      _ -> {:error, :credential_revoked}
    end
  end

  defp valid_candidate(candidate) do
    if Enum.sort(Map.keys(candidate)) == Enum.sort(@candidate_keys) and
         valid_id?(candidate.repository_id) and valid_id?(candidate.local_resource_id) and
         valid_id?(candidate.local_version) and candidate.resource_kind == :label and
         candidate.local_resource_type == "ForgeIssues.Label" and valid_fields?(candidate.fields),
       do: :ok,
       else: {:error, :invalid_label_effect}
  end

  defp valid_confirmation(candidate, confirmation) do
    if Enum.sort(Map.keys(confirmation)) ==
         Enum.sort([:confirmed_snapshot, :github_node_id, :github_object_id]) and
         valid_id?(confirmation.github_object_id) and
         valid_text?(confirmation.github_node_id, 255) and confirmation.github_node_id != "" and
         confirmation.confirmed_snapshot == candidate_fields(candidate),
       do: :ok,
       else: {:error, :invalid_confirmation}
  end

  defp valid_conflict_input(operation, kind, remote) do
    phase = get_in(operation.external_effect_marker || %{}, ["phase"])

    valid_kind =
      (phase in ["remote_cas_pending", "metadata_issue_pending"] and
         kind in [:label_namespace_collision, :label_identity_conflict]) or
        (phase == "metadata_label_pending" and
           kind in [
             :ambiguous_label_create,
             :label_identity_conflict,
             :label_metadata_conflict
           ])

    if valid_kind and byte_size(JSON.encode!(remote)) <= 65_536,
      do: :ok,
      else: {:error, :invalid_label_effect}
  rescue
    _ -> {:error, :invalid_label_effect}
  end

  defp validate_deterministic_conflict(context, candidate, :label_metadata_conflict, _remote) do
    case exact_candidate(context, candidate, :minimum) do
      {:error, :label_metadata_conflict} -> :ok
      {:ok, _current} -> {:error, :label_metadata_not_conflicting}
    end
  end

  defp validate_deterministic_conflict(context, candidate, :label_identity_conflict, remote) do
    confirmation = %{
      github_object_id: remote["id"],
      github_node_id: remote["node_id"]
    }

    with {:ok, _current} <- exact_candidate(context, candidate, :minimum),
         true <-
           valid_id?(confirmation.github_object_id) and
             valid_text?(confirmation.github_node_id, 255) and confirmation.github_node_id != "",
         {:error, :identity_conflict} <- identity_available(context, confirmation, nil) do
      :ok
    else
      false -> {:error, :invalid_label_effect}
      :ok -> {:error, :label_identity_not_conflicting}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_deterministic_conflict(
         _context,
         _candidate,
         kind,
         _remote
       )
       when kind in [:ambiguous_label_create, :label_namespace_collision],
       do: :ok

  defp validate_deterministic_conflict(_, _, _, _), do: {:error, :invalid_label_effect}

  defp effect(candidate, observation) do
    fields = candidate_fields(candidate)
    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(fields)

    %{
      "v" => 1,
      "action" => "create_remote_label",
      "resource_kind" => "label",
      "local_label_id" => candidate.local_resource_id,
      "expected_local_version" => candidate.local_version,
      "expected_local_fingerprint" => fingerprint,
      "expected_remote_absent" => true,
      "label_name" => fields["name"],
      "proposed_fingerprint" => fingerprint,
      "proposed_snapshot" => fields,
      "observed_pull_updated_at" => DateTime.to_iso8601(observation.pull.remote_updated_at),
      "observed_issue_updated_at" => DateTime.to_iso8601(observation.issue.remote_updated_at)
    }
  end

  defp candidate(effect, repository_id) do
    fields = effect["proposed_snapshot"]

    %{
      repository_id: repository_id,
      resource_kind: :label,
      local_resource_type: "ForgeIssues.Label",
      local_resource_id: effect["local_label_id"],
      local_version: effect["expected_local_version"],
      fields: fields
    }
  end

  defp candidate_fields(candidate), do: candidate.fields

  defp normalize_label_row(nil), do: nil

  defp normalize_label_row(row) do
    %{
      repository_id: row.repository_id,
      resource_kind: row.resource_kind,
      local_resource_type: row.local_resource_type,
      local_resource_id: row.local_resource_id,
      local_version: row.local_version,
      fields: %{
        "name" => row.name,
        "color" => row.color,
        "description" => row.description
      }
    }
  end

  defp parent_marker(%{"phase" => "metadata_label_pending", "parent_marker" => parent}),
    do: parent

  defp parent_marker(marker), do: marker

  defp observation_current?(observation, marker) do
    with {:ok, pull_time, 0} <- DateTime.from_iso8601(marker["expected_remote_updated_at"]),
         {:ok, issue_time, 0} <-
           DateTime.from_iso8601(marker["expected_remote_issue_updated_at"]) do
      DateTime.compare(observation.pull.remote_updated_at, pull_time) != :lt and
        DateTime.compare(observation.issue.remote_updated_at, issue_time) != :lt
    else
      _ -> false
    end
  end

  defp valid_fields?(%{"name" => name, "color" => color, "description" => description} = fields)
       when map_size(fields) == 3 do
    valid_text?(name, 255) and String.trim(name) != "" and is_binary(color) and
      Regex.match?(~r/^[0-9a-f]{6}$/, String.downcase(color)) and
      (is_nil(description) or valid_text?(description, 100))
  end

  defp valid_fields?(_), do: false
  defp valid_id?(id), do: is_integer(id) and id > 0 and id <= @max_id
  defp valid_fingerprint?(value), do: is_binary(value) and byte_size(value) in 1..255

  defp fingerprint?(fields, expected) do
    case ForgeMirrors.resource_fingerprint(fields) do
      {:ok, ^expected} -> true
      _ -> false
    end
  end

  defp valid_text?(value, max) when is_binary(value),
    do:
      byte_size(value) <= max * 4 and String.valid?(value) and
        :binary.match(value, <<0>>) == :nomatch and length(String.codepoints(value)) <= max

  defp valid_text?(_, _), do: false

  defp valid_utc(%DateTime{microsecond: {0, 0}, std_offset: 0, utc_offset: 0}), do: :ok
  defp valid_utc(_), do: {:error, :invalid_argument}

  defp utc_iso8601?(value) when is_binary(value) and byte_size(value) <= 40 do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> DateTime.to_iso8601(time) == value
      _ -> false
    end
  end

  defp utc_iso8601?(_), do: false
end
