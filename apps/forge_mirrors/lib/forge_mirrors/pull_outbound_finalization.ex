defmodule ForgeMirrors.PullOutboundFinalization do
  @moduledoc """
  Recovery of one durably admitted outbound pull creation.

  Identification records paired, freshly authenticated immutable provider IDs;
  it never authorizes cleanup. Confirmation requires fresh active eligibility
  and the exact desired snapshots held by the immutable creation intent. The
  caller must hold writer fences and verify live local/provider refs through
  confirmation. This module performs no provider or Git I/O.
  """
  import Ecto.Query
  alias Fornacast.Repo

  alias ForgeMirrors.{
    MirrorResourceState,
    MirrorRefState,
    RepositoryMirror,
    PullOutboundCreation,
    PullEligibility,
    PullMergeBoundary,
    CorrelationMarker
  }

  @refs ~w(base_ref base_sha head_ref head_sha)
  @marker ~w(action creation_uuid expected_local_version intent_fingerprint intent_id issue_id phase pull_id)
  @remote ~w(github_issue_node_id github_issue_object_id github_node_id github_number github_object_id)
  @stable ~w(repository_mirror_id repository_id github_repository_id repository_generation ref oid)

  def identify(operation, %DateTime{} = now, marker, observation, lock_fun, identify_fun)
      when is_map(marker) and is_map(observation) do
    Repo.transaction(fn ->
      with {:ok, persisted, scope, intent} <- recover(operation, marker, lock_fun),
           :ok <- pair(intent, observation, :transport),
           :ok <- repositories(scope, intent, false),
           {:ok, _} <- local(intent),
           :ok <- missing(scope, intent, observation),
           {:ok, replacement} <- identified_marker(marker, observation),
           {:ok, persisted, _} <- lock_fun.(persisted),
           {:ok, identified} <- identify_fun.(persisted, now, replacement) do
        %{operation: identified, marker: replacement, intent: intent}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def identify(_, _, _, _, _, _), do: {:error, :invalid_argument}

  def confirm(
        operation,
        %DateTime{} = now,
        marker,
        observation,
        domain_fun,
        lock_fun,
        complete_fun
      )
      when is_map(marker) and is_map(observation) and is_function(domain_fun, 1) do
    Repo.transaction(fn ->
      with {:ok, persisted, scope, intent} <- recover(operation, marker, lock_fun),
           true <- marker["phase"] == "identified",
           :ok <- pair(intent, observation, :desired),
           true <- marker["remote_identity"] == remote_identity(observation),
           :ok <- repositories(scope, intent, true),
           {:ok, before} <- local(intent),
           :ok <- missing(scope, intent, observation) do
        inventory = inventory(scope.repository_id)

        with {:ok, %{resource: resource}} <- Repo.transaction(domain_fun.(Ecto.Multi.new())),
             {:ok, after_observe} <- local(intent),
             true <- before == after_observe and inventory == inventory(scope.repository_id),
             :ok <- projection(resource, after_observe, intent),
             {:ok, persisted, scope, ^intent} <- recover(persisted, marker, lock_fun),
             :ok <- repositories(scope, intent, true),
             :ok <- missing(scope, intent, observation),
             {:ok, issue_state} <- insert_mapping(scope, intent, :issue, observation.issue),
             {:ok, pull_state} <- insert_mapping(scope, intent, :pull, observation.pull),
             {:ok, persisted, _} <- lock_fun.(persisted),
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
        _ -> Repo.rollback(:invalid_transition)
      end
    end)
  end

  def confirm(_, _, _, _, _, _, _), do: {:error, :invalid_argument}

  defp recover(operation, marker, lock_fun) do
    keys =
      if marker["phase"] == "identified",
        do: Enum.sort(["remote_identity" | @marker]),
        else: @marker

    with {:ok, persisted, scope} <- lock_fun.(operation),
         true <- persisted.state == :effect_pending and Enum.sort(Map.keys(marker)) == keys,
         true <-
           marker["phase"] != "identified" or
             (is_map(marker["remote_identity"]) and
                Enum.sort(Map.keys(marker["remote_identity"])) == @remote),
         {:ok, intent} <- PullOutboundCreation.lock_recovery(persisted, scope, marker) do
      {:ok, persisted, scope, intent}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_creation_intent}
    end
  end

  defp pair(intent, %{pull: pull, issue: issue} = observation, phase)
       when is_map(pull) and is_map(issue) do
    identity = pull[:provider_identity]
    expected = intent.payload
    {pull_snapshot, issue_snapshot} = snapshots(intent, phase)

    if map_size(observation) == 2 and valid_observation?(pull) and valid_observation?(issue) and
         is_map(identity) and map_size(identity) == 5 and
         Map.take(identity, ~w(base_repository head_repository)) ==
           expected["provider_repositories"] and
         identity["github_issue_object_id"] == issue.github_object_id and
         identity["github_issue_node_id"] == issue.github_node_id and
         identity["github_number"] == issue.github_number and
         pull.github_number == issue.github_number and
         pull.github_node_id != issue.github_node_id and
         pull[:confirmed_snapshot] == pull_snapshot and
         issue[:confirmed_snapshot] == issue_snapshot and
         pull[:confirmed_merge_state] == %{"merged_at" => nil, "merge_commit_sha" => nil} do
      :ok
    else
      {:error, :identity_conflict}
    end
  end

  defp pair(_, _, _), do: {:error, :identity_conflict}

  defp snapshots(intent, :desired),
    do: {intent.payload["pull_snapshot"], intent.payload["issue_snapshot"]}

  defp snapshots(intent, :transport) do
    {:ok, body} = CorrelationMarker.append(nil, intent.creation_uuid)
    common = %{"body" => body, "state" => "open", "state_reason" => nil}

    {Map.merge(intent.payload["pull_snapshot"], common),
     intent.payload["issue_snapshot"]
     |> Map.merge(common)
     |> Map.merge(%{"label_github_ids" => [], "assignee_github_ids" => []})}
  end

  defp identified_marker(%{"phase" => "unresolved"} = marker, observation),
    do:
      {:ok,
       marker
       |> Map.put("phase", "identified")
       |> Map.put("remote_identity", remote_identity(observation))}

  defp identified_marker(%{"phase" => "identified"} = marker, observation) do
    if marker["remote_identity"] == remote_identity(observation),
      do: {:ok, marker},
      else: {:error, :identity_conflict}
  end

  defp remote_identity(%{pull: pull, issue: issue}),
    do: %{
      "github_object_id" => pull.github_object_id,
      "github_node_id" => pull.github_node_id,
      "github_issue_object_id" => issue.github_object_id,
      "github_issue_node_id" => issue.github_node_id,
      "github_number" => pull.github_number
    }

  # Identification needs stable source identity, not permission to make another
  # effect. Re-activation may advance lock versions without changing this identity.
  defp repositories(scope, intent, active?) do
    proof = intent.payload["pull_eligibility_proof"]
    base = Repo.get!(RepositoryMirror, scope.repository_mirror_id)
    sides = [proof["base"], proof["head"]]
    ids = Enum.map(sides, & &1["repository_mirror_id"])
    local_ids = Enum.map(sides, & &1["repository_id"])

    bindings =
      Repo.all(
        from b in RepositoryMirror, where: b.id in ^ids, order_by: b.id, lock: "FOR UPDATE"
      )

    repos =
      Repo.all(
        from r in ForgeRepos.Repository,
          where: r.id in ^local_ids,
          order_by: r.id,
          lock: "FOR UPDATE"
      )

    org = Repo.get!(ForgeMirrors.OrganizationMirror, base.organization_mirror_id)
    refs = refs(intent.payload["pull_snapshot"])

    Repo.all(
      from r in MirrorRefState,
        where: r.repository_mirror_id in ^ids and r.ref_name in ^[refs.base_ref, refs.head_ref],
        order_by: r.id,
        lock: "FOR UPDATE"
    )

    valid =
      proof["organization_mirror_id"] == base.organization_mirror_id and
        proof["github_installation_id"] == scope.github_installation_id and
        proof["base"]["repository_mirror_id"] == scope.repository_mirror_id and
        proof["base"]["repository_id"] == scope.repository_id and
        Enum.all?(
          [{"base", refs.base_ref, refs.base_sha}, {"head", refs.head_ref, refs.head_sha}],
          fn {side, ref, oid} ->
            stable = proof[side]
            binding = Enum.find(bindings, &(&1.id == stable["repository_mirror_id"]))
            repository = Enum.find(repos, &(&1.id == stable["repository_id"]))
            remote = intent.payload["provider_repositories"][side <> "_repository"]

            (binding && repository &&
               binding.organization_mirror_id == base.organization_mirror_id) and
              binding.repository_id == repository.id and
              binding.github_repository_id == remote["id"] and
              binding.github_node_id == remote["node_id"] and
              binding.github_repository_id == stable["github_repository_id"] and
              repository.generation == stable["repository_generation"] and
              repository.owner_user_id == org.organization_id and
              is_nil(repository.deleted_at) and repository.lifecycle == :ready and
              stable["ref"] == ref and stable["oid"] == oid
          end
        )

    cond do
      not valid ->
        {:error, :ineligible_pull}

      not active? ->
        :ok

      true ->
        with {:ok, fresh} <- PullEligibility.check(base.id, proof["head"]["repository_id"], refs),
             fresh = json(fresh),
             true <-
               Enum.all?(
                 ~w(base head),
                 &(Map.take(fresh[&1], @stable) == Map.take(proof[&1], @stable))
               ) do
          :ok
        else
          _ -> {:error, :ineligible_pull}
        end
    end
  end

  defp local(intent) do
    issue =
      Repo.one(
        from i in "issues",
          where: i.id == ^intent.issue_id and i.repository_id == ^intent.repository_id,
          select:
            map(i, [
              :id,
              :repository_id,
              :kind,
              :number,
              :sync_version,
              :title,
              :body,
              :state,
              :state_reason
            ]),
          lock: "FOR UPDATE"
      )

    pull =
      Repo.one(
        from p in "pull_requests",
          where: p.id == ^intent.pull_id and p.repository_id == ^intent.repository_id,
          select:
            map(p, [
              :id,
              :issue_id,
              :repository_id,
              :head_repository_id,
              :draft,
              :head_ref,
              :head_sha,
              :base_ref,
              :base_sha,
              :merged_at,
              :merge_commit_sha
            ]),
          lock: "FOR UPDATE"
      )

    if issue && pull && issue.kind == "pull_request" && pull.issue_id == issue.id &&
         issue.sync_version >= intent.local_version &&
         pull.head_repository_id ==
           intent.payload["pull_eligibility_proof"]["head"]["repository_id"] &&
         is_nil(pull.merged_at) && is_nil(pull.merge_commit_sha) &&
         json(Map.take(pull, ~w(base_ref base_sha head_ref head_sha)a)) ==
           Map.take(intent.payload["pull_snapshot"], @refs) do
      with :ok <- PullMergeBoundary.check_pull_unreserved(intent.repository_id, intent.pull_id) do
        labels =
          Repo.all(
            from l in "issue_labels",
              where: l.issue_id == ^issue.id,
              order_by: l.label_id,
              select: l.label_id,
              lock: "FOR UPDATE"
          )

        assignees =
          Repo.all(
            from a in "issue_assignees",
              where: a.issue_id == ^issue.id,
              order_by: a.id,
              select: {a.user_id, a.github_identity_id},
              lock: "FOR UPDATE"
          )

        {:ok, %{issue: issue, pull: pull, labels: labels, assignees: assignees}}
      end
    else
      {:error, :stale_local_snapshot}
    end
  end

  defp projection(resource, %{issue: issue, pull: pull}, intent) when is_map(resource) do
    fields =
      Map.merge(
        Map.take(issue, ~w(title body state state_reason)a),
        Map.take(pull, ~w(draft base_ref base_sha head_ref head_sha)a)
      )
      |> json()

    if resource[:repository_id] == intent.repository_id and resource[:resource_kind] == :pull and
         resource[:local_resource_type] == "ForgePulls.PullRequest" and
         resource[:local_resource_id] == pull.id and
         resource[:issue_id] == issue.id and resource[:issue_number] == issue.number and
         resource[:head_repository_id] == pull.head_repository_id and
         resource[:local_version] == issue.sync_version and
         resource[:fields] == fields and
         resource[:merge_state] == %{merged_at: nil, merge_commit_sha: nil},
       do: :ok,
       else: {:error, :invalid_projection}
  end

  defp projection(_, _, _), do: {:error, :invalid_projection}

  defp inventory(repository_id) do
    {Repo.one(
       from i in "issues",
         where: i.repository_id == ^repository_id,
         select: {count(i.id), max(i.id)}
     ),
     Repo.one(
       from p in "pull_requests",
         where: p.repository_id == ^repository_id,
         select: {count(p.id), max(p.id)}
     )}
  end

  defp missing(scope, intent, observation) do
    nodes = [observation.pull.github_node_id, observation.issue.github_node_id]

    collision =
      Repo.exists?(
        from m in MirrorResourceState,
          where: m.repository_mirror_id == ^scope.repository_mirror_id,
          where:
            m.github_node_id in ^nodes or
              (m.resource_kind in [:issue, :pull] and
                 m.github_number == ^observation.pull.github_number) or
              (m.resource_kind == :pull and
                 (m.github_object_id == ^observation.pull.github_object_id or
                    m.local_resource_id == ^intent.pull_id)) or
              (m.resource_kind == :issue and
                 (m.github_object_id == ^observation.issue.github_object_id or
                    m.local_resource_id == ^intent.issue_id))
      )

    if collision, do: {:error, :identity_conflict}, else: :ok
  end

  defp insert_mapping(scope, intent, kind, observation) do
    {local_id, type} =
      if kind == :pull,
        do: {intent.pull_id, "ForgePulls.PullRequest"},
        else: {intent.issue_id, "ForgeIssues.Issue"}

    extra =
      if kind == :pull,
        do: Map.take(observation, [:provider_identity, :confirmed_merge_state]),
        else: %{}

    with {:ok, hash} <- ForgeMirrors.resource_fingerprint(observation.confirmed_snapshot) do
      %MirrorResourceState{}
      |> MirrorResourceState.persistence_changeset(
        Map.merge(
          %{
            repository_mirror_id: scope.repository_mirror_id,
            resource_kind: kind,
            local_resource_id: local_id,
            local_resource_type: type,
            github_object_id: observation.github_object_id,
            github_node_id: observation.github_node_id,
            github_number: observation.github_number,
            confirmed_local_version: intent.local_version,
            confirmed_remote_updated_at: observation.remote_updated_at,
            confirmed_snapshot: observation.confirmed_snapshot,
            confirmed_fingerprint: hash,
            state: :confirmed
          },
          extra
        )
      )
      |> Repo.insert()
    end
  end

  defp valid_observation?(observation),
    do:
      id?(observation[:github_object_id]) and id?(observation[:github_number]) and
        node?(observation[:github_node_id]) and utc?(observation[:remote_updated_at])

  defp id?(id), do: is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807
  defp node?(node), do: is_binary(node) and byte_size(node) in 1..255 and String.valid?(node)
  defp utc?(%DateTime{utc_offset: 0, std_offset: 0, microsecond: {0, 0}}), do: true
  defp utc?(_), do: false

  defp refs(snapshot),
    do: %{
      base_ref: snapshot["base_ref"],
      base_sha: snapshot["base_sha"],
      head_ref: snapshot["head_ref"],
      head_sha: snapshot["head_sha"]
    }

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
