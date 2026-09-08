defmodule ForgeMirrors.PullCreationBoundary do
  @moduledoc """
  Atomic admission of a newly observed remote pull and its canonical issue.

  The provider caller must freshly authenticate and normalize BOTH observations,
  and verify live Git refs before supplying a persisted eligibility proof. This
  boundary does no HTTP or Git I/O. It rechecks the leased scope and persisted
  proof under locks, then commits the domain aggregate and both mappings together.
  """
  import Ecto.Query
  alias Fornacast.Repo

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorResourceState,
    MirrorRefState,
    RepositoryMirror,
    OrganizationMirror,
    GitHubAppInstallation,
    PullEligibility
  }

  @issue_fields ~w(body state state_reason title)
  @pull_fields ~w(base_ref base_sha body draft head_ref head_sha state state_reason title)
  @issue_snapshot ~w(assignee_github_ids body label_github_ids state state_reason title)

  @doc "Leased routing facts for a genuinely missing remote pull; no provider effects occur."
  def context(%MirrorOperation{} = operation, lock_fun) when is_function(lock_fun, 1) do
    Repo.transaction(fn ->
      with {:ok, persisted, scope} <- lock_fun.(operation),
           :ok <- discovery_cursor(persisted),
           {:ok, binding} <- discovery_base(scope),
           false <- discovery_mapping_exists?(scope, persisted.cursor) do
        cursor = persisted.cursor

        Map.merge(scope, %{
          mode: :inbound_create,
          trigger: if(cursor["trigger"] == "remote", do: :remote, else: :reconcile),
          github_repository_node_id: binding.github_node_id,
          github_object_id: cursor["github_object_id"],
          github_number: cursor["github_number"],
          effect_marker: nil,
          provenance: %{
            delivery_guid: cursor["delivery_guid"],
            outbox_event_id: nil,
            causation_id: cursor["causation_id"],
            correlation_id: cursor["correlation_id"]
          }
        })
      else
        true -> Repo.rollback(:identity_conflict)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def context(_, _), do: {:error, :invalid_argument}

  defp discovery_cursor(operation) do
    cursor = operation.cursor

    if operation.state == :processing and is_nil(operation.external_effect_marker) and
         is_nil(operation.effect_marked_at) and cursor["trigger"] in ["remote", "reconcile"] and
         cursor["resource_kind"] == "pull" and id?(cursor["github_object_id"]) and
         id?(cursor["github_number"]) and
         Enum.all?(
           ~w(issue_id local_resource_id sync_version outbox_event_id),
           &(not Map.has_key?(cursor, &1))
         ), do: :ok, else: {:error, :invalid_transition}
  end

  defp discovery_base(scope) do
    row =
      Repo.one(
        from b in RepositoryMirror,
          join: o in OrganizationMirror,
          on: o.id == b.organization_mirror_id,
          join: r in ForgeRepos.Repository,
          on: r.id == b.repository_id,
          join: u in ForgeAccounts.User,
          on: u.id == o.organization_id,
          join: i in GitHubAppInstallation,
          on:
            i.github_installation_id == o.github_installation_id and
              i.github_account_id == o.github_account_id,
          where:
            b.id == ^scope.repository_mirror_id and b.state == :active and b.inventory_included and
              o.state == :active and
              r.lifecycle == :ready and is_nil(r.deleted_at) and r.generation > 0 and
              r.owner_user_id == o.organization_id and
              u.kind == :organization and u.state == :active and i.state == :active,
          select: {b, o.capabilities},
          lock: "FOR UPDATE"
      )

    case row do
      {binding, capabilities} ->
        if id?(binding.github_repository_id) and node?(binding.github_node_id) and
             capabilities["git"] in [true, "enabled", "active"],
           do: {:ok, binding},
           else: {:error, :ineligible_pull}

      nil ->
        {:error, :ineligible_pull}
    end
  end

  defp discovery_mapping_exists?(scope, cursor) do
    Repo.exists?(
      from m in MirrorResourceState,
        where:
          m.repository_mirror_id == ^scope.repository_mirror_id and
            ((m.resource_kind == :pull and m.github_object_id == ^cursor["github_object_id"]) or
               (m.resource_kind in [:issue, :pull] and m.github_number == ^cursor["github_number"]))
    )
  end

  def confirm(
        %MirrorOperation{} = operation,
        %DateTime{} = now,
        expected,
        observation,
        domain_fun,
        lock_fun,
        complete_fun
      )
      when is_map(expected) and is_map(observation) and is_function(domain_fun, 1) and
             is_function(lock_fun, 1) and is_function(complete_fun, 2) do
    with :ok <- validate_pair(expected, observation),
         {:ok, pull_fingerprint} <-
           ForgeMirrors.resource_fingerprint(observation.pull.confirmed_snapshot),
         {:ok, issue_fingerprint} <-
           ForgeMirrors.resource_fingerprint(observation.issue.confirmed_snapshot) do
      Repo.transaction(fn ->
        with {:ok, persisted, scope} <- lock_fun.(operation),
             :ok <- remote_creation?(persisted, observation),
             :ok <- eligible(scope, expected, observation.pull),
             :ok <- identities_missing(scope, observation) do
          before = high_water(scope.repository_id)

          with {:ok, %{resource: resource}} <- Repo.transaction(domain_fun.(Ecto.Multi.new())),
               :ok <- persisted_projection(scope, expected, observation, resource, before),
               {:ok, persisted, scope} <- lock_fun.(operation),
               :ok <- remote_creation?(persisted, observation),
               :ok <- eligible(scope, expected, observation.pull),
               :ok <- identities_missing(scope, observation),
               {:ok, issue_state} <-
                 insert_mapping(
                   scope,
                   :issue,
                   resource.issue_id,
                   "ForgeIssues.Issue",
                   observation.issue,
                   issue_fingerprint,
                   :confirmed,
                   %{}
                 ),
               {:ok, pull_state} <-
                 insert_mapping(
                   scope,
                   :pull,
                   resource.local_resource_id,
                   "ForgePulls.PullRequest",
                   observation.pull,
                   pull_fingerprint,
                   if(is_nil(expected.head_repository_id), do: :unsupported, else: :confirmed),
                   Map.take(observation.pull, [:provider_identity, :confirmed_merge_state])
                 ),
               {:ok, persisted, _} <- lock_fun.(operation),
               {:ok, completed} <- complete_fun.(persisted, now) do
            %{
              operation: completed,
              resource: resource,
              issue_state: issue_state,
              pull_state: pull_state
            }
          else
            {:error, _step, reason, _changes} -> Repo.rollback(reason)
            {:error, reason} -> Repo.rollback(reason)
            _ -> Repo.rollback(:invalid_projection)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def confirm(_, _, _, _, _, _, _), do: {:error, :invalid_argument}

  @doc false
  def validate_pair(
        %{head_repository_id: head, pull_eligibility_proof: proof} = expected,
        %{pull: pull, issue: issue} = observation
      )
      when is_map(pull) and is_map(issue) do
    identity = pull[:provider_identity]

    valid =
      map_size(expected) == 2 and map_size(observation) == 2 and
        (is_nil(head) or id?(head)) and (is_nil(proof) or is_map(proof)) and
        valid_observation?(pull) and valid_observation?(issue) and
        is_map(identity) and
        Enum.sort(Map.keys(identity)) ==
          ~w(base_repository github_issue_node_id github_issue_object_id github_number head_repository) and
        repository_identity?(identity["base_repository"]) and
        (is_nil(identity["head_repository"]) or repository_identity?(identity["head_repository"])) and
        identity["github_issue_object_id"] == issue.github_object_id and
        identity["github_issue_node_id"] == issue.github_node_id and
        identity["github_number"] == issue.github_number and
        pull.github_number == issue.github_number and
        pull.github_node_id != issue.github_node_id and
        is_map(pull[:confirmed_snapshot]) and
        Enum.sort(Map.keys(pull.confirmed_snapshot)) == @pull_fields and
        is_map(issue[:confirmed_snapshot]) and
        Enum.sort(Map.keys(issue.confirmed_snapshot)) == @issue_snapshot and
        Map.take(pull.confirmed_snapshot, @issue_fields) ==
          Map.take(issue.confirmed_snapshot, @issue_fields) and
        valid_ids?(issue.confirmed_snapshot["label_github_ids"]) and
        valid_ids?(issue.confirmed_snapshot["assignee_github_ids"]) and
        valid_merge?(pull[:confirmed_merge_state], pull.confirmed_snapshot["state"])

    if valid, do: :ok, else: {:error, :identity_conflict}
  end

  def validate_pair(_, _), do: {:error, :invalid_argument}

  defp valid_observation?(value),
    do:
      id?(value[:github_object_id]) and id?(value[:github_number]) and
        node?(value[:github_node_id]) and utc?(value[:remote_updated_at])

  defp repository_identity?(%{"id" => id, "node_id" => node} = value),
    do: map_size(value) == 2 and id?(id) and node?(node)

  defp repository_identity?(_), do: false

  defp valid_ids?(ids) when is_list(ids),
    do: length(ids) <= 100 and ids == Enum.sort(Enum.uniq(ids)) and Enum.all?(ids, &id?/1)

  defp valid_ids?(_), do: false
  defp id?(id), do: is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807

  defp node?(node),
    do:
      is_binary(node) and byte_size(node) in 1..255 and String.valid?(node) and
        String.trim(node) == node and not String.contains?(node, <<0>>)

  defp utc?(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: true
  defp utc?(_), do: false

  defp valid_merge?(%{"merged_at" => nil, "merge_commit_sha" => nil} = value, _),
    do: map_size(value) == 2

  defp valid_merge?(%{"merged_at" => at, "merge_commit_sha" => sha} = value, "closed")
       when is_binary(at) and is_binary(sha) do
    map_size(value) == 2 and Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, sha) and
      match?({:ok, _, 0}, DateTime.from_iso8601(at))
  end

  defp valid_merge?(_, _), do: false

  defp remote_creation?(operation, observation) do
    cursor = operation.cursor

    if operation.state == :processing and is_nil(operation.external_effect_marker) and
         is_nil(operation.effect_marked_at) and cursor["trigger"] in ["remote", "reconcile"] and
         cursor["github_object_id"] == observation.pull.github_object_id and
         cursor["github_number"] == observation.pull.github_number and
         cursor["resource_kind"] == "pull" and
         cursor["github_issue_id"] in [nil, observation.issue.github_object_id] and
         Enum.all?(
           ~w(issue_id local_resource_id sync_version outbox_event_id),
           &(not Map.has_key?(cursor, &1))
         ), do: :ok, else: {:error, :invalid_transition}
  end

  defp eligible(scope, expected, pull) do
    base = Repo.get!(RepositoryMirror, scope.repository_mirror_id)
    identity = pull.provider_identity
    head_identity = identity["head_repository"]
    head_repository_id = expected.head_repository_id || scope.repository_id

    candidates =
      if is_nil(head_identity),
        do: dynamic([b], b.id == ^base.id or b.repository_id == ^head_repository_id),
        else:
          dynamic(
            [b],
            b.id == ^base.id or b.github_repository_id == ^head_identity["id"] or
              b.github_node_id == ^head_identity["node_id"] or
              b.repository_id == ^head_repository_id
          )

    # The organization lock serializes binding changes, including the absence
    # proof. Read only the exact possible head identities, never the whole org.
    bindings =
      Repo.all(
        from b in RepositoryMirror,
          where: b.organization_mirror_id == ^base.organization_mirror_id,
          where: ^candidates,
          order_by: b.id,
          limit: 4,
          lock: "FOR UPDATE"
      )

    heads =
      if is_nil(head_identity),
        do: [],
        else:
          Enum.filter(
            bindings,
            &(&1.github_repository_id == head_identity["id"] or
                &1.github_node_id == head_identity["node_id"])
          )

    repository_ids =
      [scope.repository_id, expected.head_repository_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    Repo.all(
      from r in ForgeRepos.Repository,
        where: r.id in ^repository_ids,
        order_by: r.id,
        lock: "FOR UPDATE"
    )

    org = Repo.get!(OrganizationMirror, base.organization_mirror_id)

    Repo.all(
      from u in ForgeAccounts.User, where: u.id == ^org.organization_id, lock: "FOR UPDATE"
    )

    Repo.all(
      from i in GitHubAppInstallation,
        where: i.github_installation_id == ^scope.github_installation_id,
        lock: "FOR UPDATE"
    )

    ids = Enum.map(bindings, & &1.id)
    refs = refs(pull.confirmed_snapshot)

    Repo.all(
      from r in MirrorRefState,
        where: r.repository_mirror_id in ^ids and r.ref_name in ^[refs.base_ref, refs.head_ref],
        order_by: r.id,
        lock: "FOR UPDATE"
    )

    cond do
      length(bindings) > 2 ->
        {:error, :ineligible_pull}

      identity["base_repository"] != %{
        "id" => base.github_repository_id,
        "node_id" => base.github_node_id
      } ->
        {:error, :ineligible_pull}

      is_nil(expected.head_repository_id) ->
        base_refs = %{refs | head_ref: refs.base_ref, head_sha: refs.base_sha}

        if heads == [] and is_nil(expected.pull_eligibility_proof) and
             match?({:ok, _}, PullEligibility.check(base.id, base.repository_id, base_refs)),
           do: :ok,
           else: {:error, :ineligible_pull}

      true ->
        with [head] <- heads,
             true <-
               head.repository_id == expected.head_repository_id and
                 head.github_repository_id == head_identity["id"] and
                 head.github_node_id == head_identity["node_id"],
             {:ok, proof} <- PullEligibility.check(base.id, expected.head_repository_id, refs),
             true <- json(proof) == expected.pull_eligibility_proof do
          :ok
        else
          _ -> {:error, :ineligible_pull}
        end
    end
  end

  defp identities_missing(scope, observation) do
    pull = observation.pull
    issue = observation.issue
    nodes = [pull.github_node_id, issue.github_node_id]

    collision =
      Repo.exists?(
        from m in MirrorResourceState,
          where: m.repository_mirror_id == ^scope.repository_mirror_id,
          where:
            m.github_node_id in ^nodes or
              (m.resource_kind in [:issue, :pull] and m.github_number == ^pull.github_number) or
              (m.resource_kind == :issue and m.github_object_id == ^issue.github_object_id) or
              (m.resource_kind == :pull and m.github_object_id == ^pull.github_object_id)
      )

    if collision, do: {:error, :identity_conflict}, else: :ok
  end

  defp high_water(repository_id) do
    %{
      issue:
        Repo.one(from i in "issues", where: i.repository_id == ^repository_id, select: max(i.id)) ||
          0,
      pull:
        Repo.one(
          from p in "pull_requests", where: p.repository_id == ^repository_id, select: max(p.id)
        ) || 0
    }
  end

  defp persisted_projection(scope, expected, observation, resource, before)
       when is_map(resource) do
    with %{
           repository_id: repository_id,
           resource_kind: :pull,
           local_resource_type: "ForgePulls.PullRequest",
           local_resource_id: pull_id,
           issue_id: issue_id,
           issue_number: number,
           local_version: 1
         } <- resource,
         true <-
           repository_id == scope.repository_id and id?(pull_id) and id?(issue_id) and
             pull_id > before.pull and issue_id > before.issue,
         [^issue_id] <-
           Repo.all(
             from i in "issues",
               where: i.repository_id == ^repository_id and i.id > ^before.issue,
               order_by: i.id,
               limit: 2,
               select: i.id
           ),
         [^pull_id] <-
           Repo.all(
             from p in "pull_requests",
               where: p.repository_id == ^repository_id and p.id > ^before.pull,
               order_by: p.id,
               limit: 2,
               select: p.id
           ),
         %{kind: "pull_request", number: ^number, sync_version: 1} = issue <-
           Repo.one(
             from i in "issues",
               where: i.id == ^issue_id and i.repository_id == ^repository_id,
               select: %{
                 kind: i.kind,
                 number: i.number,
                 sync_version: i.sync_version,
                 title: i.title,
                 body: i.body,
                 state: i.state,
                 state_reason: i.state_reason
               },
               lock: "FOR UPDATE"
           ),
         %{} = pull <-
           Repo.one(
             from p in "pull_requests",
               where:
                 p.id == ^pull_id and p.issue_id == ^issue_id and
                   p.repository_id == ^repository_id,
               select: %{
                 head_repository_id: p.head_repository_id,
                 head_ref: p.head_ref,
                 base_ref: p.base_ref,
                 head_sha: p.head_sha,
                 base_sha: p.base_sha,
                 draft: p.draft,
                 merged_at: p.merged_at,
                 merge_commit_sha: p.merge_commit_sha
               },
               lock: "FOR UPDATE"
           ),
         true <-
           pull.head_repository_id == expected.head_repository_id and
             resource[:head_repository_id] == expected.head_repository_id,
         fields =
           json(
             Map.merge(
               Map.take(issue, [:title, :body, :state, :state_reason]),
               Map.take(pull, [:head_ref, :base_ref, :head_sha, :base_sha, :draft])
             )
           ),
         true <- fields == observation.pull.confirmed_snapshot and resource[:fields] == fields,
         true <-
           json(Map.take(pull, [:merged_at, :merge_commit_sha])) ==
             observation.pull.confirmed_merge_state and
             json(resource[:merge_state]) == observation.pull.confirmed_merge_state,
         :ok <-
           verify_relationships(
             scope.repository_mirror_id,
             issue_id,
             resource,
             observation.issue.confirmed_snapshot
           ) do
      :ok
    else
      _ -> {:error, :invalid_projection}
    end
  end

  defp persisted_projection(_, _, _, _, _), do: {:error, :invalid_projection}

  defp verify_relationships(binding_id, issue_id, resource, snapshot) do
    labels =
      Repo.all(
        from l in "issue_labels",
          where: l.issue_id == ^issue_id,
          order_by: l.label_id,
          select: l.label_id
      )

    assignees =
      Repo.all(
        from a in "issue_assignees",
          where: a.issue_id == ^issue_id,
          select: {a.user_id, a.github_identity_id}
      )

    refs =
      Enum.map(assignees, fn
        {nil, id} -> %{kind: :github_identity, id: id}
        {id, nil} -> %{kind: :local_user, id: id}
        _ -> :invalid
      end)
      |> Enum.sort()

    with true <- resource[:label_ids] == labels and resource[:assignee_refs] == refs,
         {:ok, resolved} <-
           ForgeMirrors.resolve_issue_relationships(binding_id, :local, labels, refs),
         true <-
           Enum.sort(Enum.map(resolved.labels, & &1.github_object_id)) ==
             snapshot["label_github_ids"] and
             Enum.sort(Enum.map(resolved.assignees, & &1.github_user_id)) ==
               snapshot["assignee_github_ids"] do
      :ok
    else
      _ -> {:error, :invalid_projection}
    end
  end

  defp insert_mapping(scope, kind, local_id, type, observation, fingerprint, state, extra) do
    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(
      Map.merge(
        %{
          repository_mirror_id: scope.repository_mirror_id,
          resource_kind: kind,
          local_resource_type: type,
          local_resource_id: local_id,
          github_object_id: observation.github_object_id,
          github_node_id: observation.github_node_id,
          github_number: observation.github_number,
          confirmed_local_version: 1,
          confirmed_remote_updated_at: observation.remote_updated_at,
          confirmed_snapshot: observation.confirmed_snapshot,
          confirmed_fingerprint: fingerprint,
          state: state
        },
        extra
      )
    )
    |> Ecto.Changeset.unique_constraint(:github_object_id,
      name: :mirror_resource_states_github_identity_index
    )
    |> Ecto.Changeset.unique_constraint(:local_resource_id,
      name: :mirror_resource_states_local_identity_index
    )
    |> Repo.insert()
  end

  defp refs(fields),
    do: %{
      base_ref: fields["base_ref"],
      base_sha: fields["base_sha"],
      head_ref: fields["head_ref"],
      head_sha: fields["head_sha"]
    }

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
